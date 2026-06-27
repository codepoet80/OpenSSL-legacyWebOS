# Modern TLS for the HP TouchPad (webOS 3.0.5) stock browser

Bring TLS 1.2 / 1.3 to the **stock** webOS 3.0.5 browser on the HP TouchPad, so it
can actually connect to today's HTTPS websites — without replacing the browser,
the OS, or any system binary's behaviour for the rest of the device.

webOS 3.0.5 ships **OpenSSL 0.9.8** (TLS 1.0 only). Modern sites refuse TLS 1.0,
so the built-in browser can no longer reach them. This project gives **only the
browser process** a private, modern OpenSSL 1.1.1w + curl stack, leaving the rest
of the 2011 OS untouched.

---

## What it DOES

- ✅ **TLS 1.2 and TLS 1.3** in the stock `BrowserServer` (modern ciphers, SNI, etc.)
- ✅ **Validates current certificates** against an up-to-date Mozilla CA bundle
- ✅ **gzip/deflate** content decoding (curl built with zlib) — required for most sites
- ✅ **Process-private**: the modern OpenSSL/curl live in `/usr/lib/ssl11` and are
  loaded **only** by the browser. Wi‑Fi, VPN, e‑mail, `keymanager`, Node services,
  etc. keep using the original 0.9.8 and are completely unaffected.
- ✅ **Survives reboots** and is **launcher-independent** (works no matter how webOS
  starts `BrowserServer`).
- ✅ **Auto clock sync** (separate package): webOS's own time sync targets dead
  `palm.com` servers, so the clock drifts and breaks certificate validity windows.
  A small NTP job fixes this.
- ✅ **Cleanly removable** — every change is reversible via package removal.

## What it does NOT do

- ❌ **It does not upgrade the rendering engine.** The browser is still 2011-era
  WebKit. Modern TLS gets you *connected* and the page *downloaded*, but heavy
  modern sites (lots of JavaScript, modern CSS, SPAs) will render **blank or
  partially**, or their interactive features (e.g. logins) won't work. This is an
  engine limitation that no TLS change can fix — only a newer browser engine
  (e.g. the LuneOS / Qt‑WebEngine route) would.
- ❌ **It does not bypass bot/WAF blocks.** Sites behind Cloudflare "managed
  challenge" or strict bot rules (e.g. telegraaf.nl) will serve a *"you have been
  blocked"* page. That's the server refusing the old client, not a TLS failure.
- ❌ **It does not change the User-Agent.** The browser still identifies as webOS.
  (A UA override is a one-line edit to `/etc/palm/browser-app.conf`
  — `UserAgentOverride=...` — kept deliberately *out* of these packages.)
- ❌ **It does not modify system-wide OpenSSL/curl.** Other apps/services stay on
  0.9.8 on purpose (changing them globally bricks boot — Wi‑Fi/VPN/Node crash).
  See *Effect on curl / libcurl* below for exactly what is and isn't touched.
- ❌ **No brotli.** curl advertises gzip only. The rare site that serves *only*
  brotli won't decode. (gzip covers virtually everything.)
- ❌ **It does not ship a CA bundle.** It relies on a current
  `/etc/ssl/certs/ca-certificates.crt` — see Requirements.

### Effect on curl / libcurl

This trips people up, so to be explicit:

- ✅ A **modern curl 7.88.1** (OpenSSL 1.1.1w, **with zlib**) is installed as
  `/usr/lib/ssl11/libcurl.so.4.8.0` — and is used **only by the browser** (loaded
  through the browser's RPATH).
- ❌ The **system `/usr/lib/libcurl.so.4` (7.21.7 / OpenSSL 0.9.8) is NOT
  replaced.** Every other libcurl consumer on the device — `LunaSysMgr`,
  `PmNetConfigManager`, `keymanager`, the download manager, app/JS services,
  etc. — keeps using the old curl and is **still limited to TLS 1.0**. This is
  intentional, for the same isolation reason as OpenSSL (a global swap breaks
  unrelated services).
- ❌ The system **`/usr/bin/curl` command-line binary is NOT replaced** either —
  running `curl` from a shell still uses the old 0.9.8 stack (TLS 1.0).
- ⚙️ You can still use the modern curl **on demand** from a shell without
  installing anything extra, because libcurl's SONAME/ABI is stable — point the
  stock `curl` binary at the new library:
  ```sh
  LD_LIBRARY_PATH=/usr/lib/ssl11 curl https://example.com/
  ```
- **Bottom line:** this package gives modern TLS to the **browser only**. It does
  *not* upgrade TLS for system downloads, OTA/app updates, Preware/ipkg fetches,
  or other curl-based services.

---

## Requirements

- **HP TouchPad, webOS 3.0.5** (Doctor 3.0.5 / "doctor305"). This is the only
  tested build. See *Compatibility* below.
- A **current Mozilla CA bundle** at `/etc/ssl/certs/ca-certificates.crt`
  (install your `ca-certificates` ipk). The stock bundle is a single 2011 cert
  and will fail to validate modern sites. The browser package **warns** if it
  finds a stale bundle but does not install one.
- Wi‑Fi with working DNS (for the clock-sync package).

## Packages

Both are standard webos-internals-style ipks (install via **Preware**, **WebOS
Quick Install**, or `ipkg install`):

| Package | What it installs |
|---|---|
| `org.webosinternals.browser-tls13` | OpenSSL 1.1.1w + curl(zlib) + compat shim in `/usr/lib/ssl11`, and an RPATH-patched `/usr/bin/BrowserServer` pointing at it. |
| `org.webosinternals.ntpdate-sync` | An upstart job that syncs the clock from public NTP at boot (retry-until-success) and every 6 h. |

Removing `browser-tls13` restores the stock `BrowserServer` and deletes
`/usr/lib/ssl11`.

---

## How it works (for the curious)

The browser's TLS lives in two binaries: **`libcurl`** (the actual TLS engine) and
**`libWebKitLuna`** (which has a small cert-verification callback). Both are
compiled against the 0.9.8 ABI.

1. **Private modern stack.** A new OpenSSL 1.1.1w + curl 7.88 (with zlib) are
   installed in `/usr/lib/ssl11`, alongside symlinks named like the old
   `libssl.so.0.9.8` / `libcrypto.so.0.9.8` that point to the 1.1 libraries.

2. **RPATH redirect.** `/usr/bin/BrowserServer` is patched (`patchelf`) with
   `DT_RPATH=/usr/lib/ssl11` and the compat shim added as a NEEDED library. That
   makes the **whole browser process** (including `libWebKitLuna`) resolve its
   OpenSSL/curl from `/usr/lib/ssl11` — with **no environment variables**, so it
   works regardless of which webOS launcher starts the browser. No other process
   is affected.

3. **Two struct-offset fixes.** `libWebKitLuna`'s verify callback reads two OpenSSL
   struct fields at **hard-coded 0.9.8 offsets** (`ssl->ctx` at `0xD8`,
   `X509_STORE_CTX->cert` at `0x8`). The bundled OpenSSL 1.1.1w is built with those
   two fields **relocated** to the same offsets, so the callback works instead of
   crashing. (Found via Ghidra/objdump of the device binary.)

4. **Compat shim** (`libssl_compat.so`) provides the handful of 0.9.8 symbols 1.1
   dropped (`sk_*` → `OPENSSL_sk_*`, legacy init no-ops, etc.).

5. **CA bundle + clock.** curl validates against the Mozilla bundle; the NTP job
   keeps the clock correct so freshly-issued certs aren't seen as "not yet valid".

---

## Troubleshooting

Run the diagnostic on any device (`sh tls13-diag.sh`). It prints PASS/WARN/FAIL for
each component and an end-to-end curl. Common results:

| Symptom | Cause / fix |
|---|---|
| `browser-tls13 NOT-INSTALLED` / `ssl11 missing` | Install didn't apply. Use Preware/WOSQI/`ipkg install`; ensure the package version is current. |
| `BrowserServer: FAIL still STOCK` | RPATH swap skipped — usually a non-3.0.5 `BrowserServer` (see Compatibility). |
| `on ssl11: 0 maps` | Browser running on old 0.9.8 — stray duplicate upstart job, or swap didn't apply. |
| `CA bundle FAIL` | Install a current Mozilla `ca-certificates` ipk. |
| `curl http=000` right after boot | Network/clock not ready yet; retry after ~90 s (clock auto-syncs). |
| Page loads blank / "you have been blocked" | Engine limit / Cloudflare block — **not** a TLS issue (see *What it does NOT do*). |

## Compatibility

The packages are built for the exact stock **webOS 3.0.5** `BrowserServer`
(md5 `0786bdf6…`) and `libWebKitLuna` (md5 `3d90fd6e…`). The `pmPostInstall`
script only applies the RPATH swap if `/usr/bin/BrowserServer` matches the known
stock md5 (otherwise it warns and skips, leaving the browser stock).

If `tls13-diag.sh` reports a **different** `BrowserServer` or `libWebKitLuna` md5,
that device is a different webOS build — send those two files to rebuild the
matching RPATH binary / verify the struct offsets for that variant.

---

## Building from source

On a Linux host with the **PalmPDK** ARM toolchain (`/opt/PalmPDK`), `patchelf`,
and `base64`:

```sh
# Prereqs already present in this tree:
#   openssl-1.1.1w/  (patched: ssl->ctx @0xD8, X509_STORE_CTX->cert @0x8; built libssl/libcrypto.so.1.1)
#   curl-7.88.1/     (configured --with-openssl --with-zlib; built libcurl.so.4.8.0)
#   libssl_compat.so (built from openssl_compat_shim.c)
#   BrowserServer.bin (stock 3.0.5 BrowserServer)
#   ntpdate-sync     (the upstart job)

bash build-ipks.sh        # -> ipks/*.ipk
```

Key sources in this tree:
- `openssl_compat_shim.c` — the 0.9.8→1.1 compat shim (`sk_*` forwarders, init no-ops)
- `openssl-1.1.1w/ssl/ssl_local.h`, `include/crypto/x509.h` — the two relocated struct fields
- `ntpdate-sync` — the NTP upstart job (retry-until-success + IP fallbacks)
- `build-ipks.sh` — assembles both ipks in the webos-internals App-Manager convention
- `tls13-diag.sh` — on-device diagnostic

The packages are **unsigned**; sign with the webos-internals feed key before
publishing to the official feed.

---

## Credits / notes

Reverse-engineering, struct-offset analysis, packaging and testing done against a
live TouchPad over novacom. This does not modify or redistribute closed Palm/HP
binaries beyond an in-place `patchelf` of the on-device `BrowserServer` (RPATH +
NEEDED), which is reverted on package removal.
