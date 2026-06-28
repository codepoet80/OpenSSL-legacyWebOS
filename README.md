# Modern TLS for the HP TouchPad (webOS 3.0.5)

Bring TLS 1.2 / 1.3 to the HP TouchPad so it can actually connect to today's HTTPS
sites — in the **stock browser**, in **apps** (Mojo/Enyo WebKit), and on the
**command line** — without replacing the OS or changing the rest of the device's
2011 TLS behaviour.

webOS 3.0.5 ships **OpenSSL 0.9.8** (TLS 1.0 only). Modern servers refuse TLS 1.0,
so the built-in browser, app `XMLHttpRequest`s, and `curl` can no longer reach
them. This project installs a private, modern **OpenSSL 1.1.1w + curl 7.88.1**
stack in `/usr/lib/ssl11` and points exactly the consumers you want at it, leaving
the rest of the 2011 OS untouched.

> **Installing?** Jump to [Packages & install order](#packages). The TL;DR also
> lives in [`ipks/README.md`](ipks/README.md). **Building from source?** See
> [`BUILDING.md`](BUILDING.md).

---

## What it DOES

- ✅ **TLS 1.2 / 1.3 in the stock browser** (`BrowserServer`) — modern ciphers, SNI.
- ✅ **TLS 1.2 / 1.3 in apps** — Mojo/Enyo `XMLHttpRequest`, `enyo.WebService`, and
  any HTML rendered in a card, via the app WebKit host (`LunaSysMgr`/`WebAppMgr`).
- ✅ **A modern command-line `curl`** (7.88.1) — installed as both `curl11` and
  `curl` (the stock 0.9.8 binary is backed up and restored on removal).
- ✅ **Modern TLS for the stock Email app** (optional `mail-tls13` package) — the
  native mail transports reach TLS 1.2/1.3 servers. **Exchange ActiveSync (EAS) is
  working and hardware-proven** (e.g. Zoho — Mail/Contacts/Calendar/Tasks sync
  directly, no proxy); IMAP/POP/SMTP are in testing.
- ✅ **Validates current certificates** against an up-to-date Mozilla CA bundle.
- ✅ **gzip/deflate** decoding (curl built with zlib) — required for most sites.
- ✅ **Process-private & reboot-proof.** The modern stack lives in `/usr/lib/ssl11`
  and is loaded only by the browser, the app WebKit host, and the curl wrapper.
  Wi‑Fi/VPN/EAP, `keymanager`, the download manager, Node services, etc.
  keep using the original 0.9.8 and are **unaffected**. (E‑mail can be moved to
  modern TLS separately with the optional `mail-tls13` package — see Packages.)
- ✅ **Auto clock sync** (separate package): webOS's own time sync targets dead
  `palm.com` servers, so the clock drifts and breaks cert validity windows.
- ✅ **Cleanly removable** — every change is reversible via package removal.

## What it does NOT do

- ❌ **It does not upgrade the rendering engine.** Browser *and* apps still use
  2011-era WebKit. Modern TLS gets you *connected* and the page *downloaded*, but
  heavy modern sites (lots of JS, modern CSS, SPAs) will render **blank or
  partially**, and some interactive features won't work. Only a newer engine
  (e.g. the LuneOS / Qt‑WebEngine route) fixes that — no TLS change can.
- ❌ **It does not bypass bot/WAF blocks.** Sites behind Cloudflare "managed
  challenge" or strict bot rules will serve a *"you have been blocked"* page —
  the server refusing the old client, not a TLS failure.
- ❌ **It does not change the User-Agent.** The browser still identifies as webOS.
  (A UA override is a one-line edit to `/etc/palm/browser-app.conf`
  — `UserAgentOverride=...` — kept deliberately *out* of these packages.)
- ❌ **It does not upgrade TLS system-wide.** Only the browser, the app WebKit
  host, and the `curl` command are moved to 1.1. Wi‑Fi/VPN/EAP, `keymanager`,
  `PmNetConfigManager`, the OS download manager, OTA/app-catalog fetches, and
  other libcurl/OpenSSL consumers stay on 0.9.8 **on purpose** — a global swap
  bricks boot. See *Effect on curl / libcurl* below.
- ❌ **No brotli.** curl advertises gzip only. (gzip covers virtually everything.)
- ❌ **It does not ship a CA bundle.** It relies on a current
  `/etc/ssl/certs/ca-certificates.crt` — see [Requirements](#requirements).

### Effect on curl / libcurl

To be explicit, since this trips people up:

- ✅ **The `curl` command is modernized** — `curl-tls13` installs curl 7.88.1
  (OpenSSL 1.1.1w, with zlib) as `/usr/bin/curl11` **and** replaces `/usr/bin/curl`
  (stock saved to `/usr/bin/curl.0.9.8-orig`, restored on removal). Its wrapper
  defaults `CURL_CA_BUNDLE` to the system bundle so verification just works.
- ✅ **App WebKit uses modern libcurl** — `luna-tls13` makes `LunaSysMgr`/`WebAppMgr`
  load `/usr/lib/ssl11`, so app `XHR` goes over TLS 1.3.
- ❌ **The system `/usr/lib/libcurl.so.4` (7.21.7 / 0.9.8) is NOT replaced.** Other
  libcurl consumers — `PmNetConfigManager`, `keymanager`, the OS download manager,
  app/JS services — keep using the old curl and are still limited to TLS 1.0. This
  is intentional isolation (a global swap breaks unrelated services).

---

## Requirements

- **HP TouchPad, webOS 3.0.5** (Doctor 3.0.5 / "doctor305"). The only tested build
  — see [Compatibility](#compatibility).
- A **current Mozilla CA bundle** at `/etc/ssl/certs/ca-certificates.crt` (install a
  `ca-certificates` ipk; the stock 2011 bundle won't validate modern sites). The
  browser package **warns** on a stale bundle but does not install one.
- Wi‑Fi with working DNS (for the clock-sync package).

## Packages

Standard webos-internals-style ipks — install via **Preware**, **WebOS Quick
Install**, **App Catalog**, or `ipkg install`. **Install in this order:**

| # | Package | Installs |
|---|---------|----------|
| 1 | `org.webosinternals.browser-tls13` | OpenSSL 1.1.1w + curl(zlib) + compat shim in `/usr/lib/ssl11`, and an RPATH-patched `/usr/bin/BrowserServer`. **Install first** — provides `/usr/lib/ssl11` that #2 and #3 build on. |
| 2 | `org.webosinternals.luna-tls13` | Patches the `LunaSysMgr` upstart launcher to load `/usr/lib/ssl11`, moving app WebKit onto modern TLS. **Requires #1; reboot after.** |
| 3 | `org.webosinternals.curl-tls13` | Modern command-line curl as `/usr/bin/curl11` and `/usr/bin/curl`. Standalone. |
| 4 | `org.webosinternals.ntpdate-sync` | Upstart job: public NTP at boot (retry-until-success) and every 6 h. Standalone. |
| 5 | `org.webosinternals.mail-tls13` | **Optional.** Routes the stock Email app's native transports through OpenSSL 1.1.1w via a purpose-built libcurl + its own compat shim in `/usr/lib/ssl11mail`. **EAS, IMAP & SMTP all working & hardware-proven** (Zoho EAS; Fastmail IMAP/SMTP). **Requires #1 installed** (for `/usr/lib/ssl11`); no reboot needed. See [BUILDING.md](BUILDING.md). |
| 6 | `org.webosinternals.mojomail-imap-tagfix` | **Optional, standalone.** A one-byte patch to `mojomail-imap` so **strict IMAP servers (e.g. Fastmail) accept its command tags** (stock mojomail uses a `~`-prefixed tag some servers reject, hanging IMAP validation). Only needed for such servers; pairs with #5. Independent — take it or leave it. Reversible (restored on removal). See [mojomail-changes.md](mojomail-changes.md). |

After installing, **reboot once** (`browser-tls13` self-restarts the browser, but
`luna-tls13`'s launcher change applies on reboot). `luna-tls13`'s postinst refuses
to patch if `/usr/lib/ssl11` is absent, so a wrong install order can't brick the
device — it just no-ops with an error. Removing a package restores stock state.

Verify with `sh tls13-diag.sh` (expect `VERDICT: PASS`); load an HTTPS site in the
browser and in an app; `curl https://github.com`.

### Recovery (if the UI ever fails to boot)

`novacomd` runs independently of the UI. Over novacom as root:

```sh
mount -o remount,rw /
cp /var/luna/LunaSysMgr.tls13-orig /etc/event.d/LunaSysMgr   # restore stock launcher
reboot
```

> ⚠️ Never leave a launcher backup **inside** `/etc/event.d/` — upstart runs every
> file there as a job, so a stray copy becomes a duplicate, crash-looping
> `LunaSysMgr`. All backups live in `/var/luna/`.

---

## How it works (for the curious)

The browser's and apps' TLS lives in **`libcurl`** (the TLS engine) and
**`libWebKitLuna`** (a cert-verification callback), both compiled against the
0.9.8 ABI.

1. **Private modern stack.** OpenSSL 1.1.1w + curl 7.88 (with zlib) install in
   `/usr/lib/ssl11`, with symlinks named like the old `libssl.so.0.9.8` /
   `libcrypto.so.0.9.8` pointing at the 1.1 libraries.

2. **Two struct-offset fixes.** `libWebKitLuna`'s verify callback reads two OpenSSL
   fields at **hard-coded 0.9.8 offsets** (`ssl->ctx` @ `0xD8`,
   `X509_STORE_CTX->cert` @ `0x8`). The bundled 1.1.1w is built with those fields
   **relocated** to match, so the callback works instead of crashing. (Found via
   Ghidra/objdump of the device binaries.)

3. **Compat shim** (`libssl_compat.so`) provides the 0.9.8 symbols 1.1 dropped
   (`sk_*` → `OPENSSL_sk_*`, legacy init no-ops, etc.).

4. **Per-consumer wiring:**
   - **browser** (`browser-tls13`): `/usr/bin/BrowserServer` is `patchelf`'d with
     `DT_RPATH=/usr/lib/ssl11` + the shim as `NEEDED`, so the whole browser process
     resolves OpenSSL/curl from `/usr/lib/ssl11` with **no env vars**, regardless
     of launcher. No other process is affected.
   - **apps** (`luna-tls13`): the app WebKit host is `LunaSysMgr` and a `WebAppMgr`
     child it `fork()`s *without exec* (so the child shares the parent's libs — the
     whole process must move). Its **upstart launcher** gets
     `LD_LIBRARY_PATH=/usr/lib/ssl11` + the shim in `LD_PRELOAD`.
   - **curl** (`curl-tls13`): a self-contained curl under `/usr/lib/curl11`, exposed
     via a small `LD_LIBRARY_PATH` + `CURL_CA_BUNDLE` wrapper as `curl11`/`curl`.

5. **CA bundle + clock.** curl validates against the Mozilla bundle; the NTP job
   keeps the clock correct so freshly-issued certs aren't seen as "not yet valid".

> **Packaging note:** these install through the webOS App-Manager (Preware/WOSQI),
> which unpacks into `/media/cryptofs/apps` and runs a `pmPostInstall.script`, **not**
> the Debian `postinst`. The packages ship both, app-layout, offline-root aware.
> Details in [`BUILDING.md`](BUILDING.md).

---

## Troubleshooting

Run `sh tls13-diag.sh` — it prints a PASS/FAIL **VERDICT** plus per-component status
and an end-to-end curl. Common results:

| Symptom | Cause / fix |
|---|---|
| `browser-tls13 NOT-INSTALLED` / `ssl11 missing` | Install didn't apply; reinstall via Preware/WOSQI/`ipkg`. |
| `BrowserServer: FAIL still STOCK` | RPATH swap skipped — usually a non-3.0.5 `BrowserServer` (see Compatibility). |
| `on ssl11: 0 maps` | Browser on old 0.9.8 — stray duplicate upstart job, or swap didn't apply. |
| apps still on TLS 1.0 | `luna-tls13` not installed, or not rebooted; or `/usr/lib/ssl11` absent (install `browser-tls13` first). |
| `curl: (60) ... local issuer` | Stale/missing CA bundle — install a current Mozilla `ca-certificates` ipk. |
| `curl http=000` right after boot | Network/clock not ready; retry after ~90 s. |
| Page blank / "you have been blocked" | Engine limit / Cloudflare block — **not** TLS (see *What it does NOT do*). |

## Compatibility

Built for the exact stock **webOS 3.0.5** `BrowserServer` (md5 `0786bdf6…`) and
`libWebKitLuna` (md5 `3d90fd6e…`). The browser package only applies the RPATH swap
if `/usr/bin/BrowserServer` is non-stock-safe (it backs up whatever it replaces).
If `tls13-diag.sh` reports a **different** `libWebKitLuna` md5, that device is a
different webOS build — send that file to verify the struct offsets for that variant.

---

## Building from source

See **[`BUILDING.md`](BUILDING.md)** — prerequisites (`patchelf`, GNU `ar`,
auto-fetch of the stock `BrowserServer` over novacom) and `./build-ipks.sh`.

## Credits / notes

Reverse-engineering, struct-offset analysis, packaging and testing done against a
live TouchPad over novacom. This does not modify or redistribute closed Palm/HP
binaries beyond an in-place `patchelf` of the on-device `BrowserServer` (RPATH +
NEEDED), reverted on package removal. The packages are **unsigned** — sign with the
webos-internals feed key before publishing to the official feed.
