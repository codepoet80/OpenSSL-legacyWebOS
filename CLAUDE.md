# CLAUDE.md — working in this repo

Modern TLS 1.2/1.3 (OpenSSL 1.1.1w + curl 7.88.1) for the 2011 HP TouchPad
(webOS 3.0.5, stock OpenSSL 0.9.8). Four ipks put a process-private stack in
`/usr/lib/ssl11` and wire the browser, the apps, and the CLI into it. Full story:
[`README.md`](README.md). Build/maintainer details: [`BUILDING.md`](BUILDING.md).

## The four packages (install order)
1. `browser-tls13` — RPATH'd `/usr/bin/BrowserServer` → stock browser on TLS 1.3. **Ships `/usr/lib/ssl11`; install first.**
2. `luna-tls13` — patches the `LunaSysMgr` upstart launcher → app WebKit (Mojo/Enyo XHR) on TLS 1.3. **Needs #1; reboot after.**
3. `curl-tls13` — modern `/usr/bin/curl11` + `/usr/bin/curl` (stock backed up).
4. `ntpdate-sync` — NTP clock sync.

## Mail TLS — `mail-tls13` (5th package, IN PROGRESS — not shipping yet)
Goal: the stock Email app's native transports `mojomail-{eas,imap,pop,smtp}` reach modern
TLS so accounts like Zoho (`msync.zoho.com`, EAS, needs TLS 1.2) sync again. Full story in
[`BUILDING-mail.md`](BUILDING-mail.md); deep notes in the `mail-tls-eas` auto-memory.
- **Architecture:** `com.palm.app.email` is just UI → delegates to `palm://com.palm.eas/`
  etc. TLS happens in the native transports: **EAS via libcurl** (`libemail-common`'s
  `glibcurl`, multi interface), **IMAP/POP/SMTP via `libpalmsocket`** (direct OpenSSL,
  `SSLv23_method`). Launchers are the four D-Bus `*.service` files in
  `/usr/share/dbus-1/system-services/`; reload edits with **`ls-control scan-services`**
  (no UI bounce). Backups go in `/var/luna` (never `/etc/event.d`).
- **Two dead ends proven on hardware** (don't repeat): (a) pointing mojomail at ssl11's
  libcurl 7.88.1 → SIGSEGV in `curl_multi_remove_handle` (mojomail's glibcurl was built
  for curl 7.21.7+c-ares); (b) keeping STOCK libcurl 7.21.7 on ssl11 OpenSSL → TLS 1.3
  handshake succeeds then SIGSEGV inspecting the X509 cert (ssl11 OpenSSL only carries
  libWebKitLuna's partial offset relocation, not libcurl's).
- **The fix:** ship a purpose-built **libcurl ~7.51–7.61, `--enable-ares`, compiled against
  OpenSSL 1.1 headers** (so no offset assumptions) into `/usr/lib/ssl11mail` and point the
  four launchers there. `build-ipks.sh` already builds this package **if** the cross-built
  lib is at `curl-mail/lib/.libs/libcurl.so.4.*` (else it SKIPs). Validate with
  `mail-tls13-diag.sh` on a TEST tablet; iterate curl version if needed. IMAP/POP/SMTP
  (libpalmsocket) is a separate validation — may also need wider OpenSSL offset relocation.
- **Build host:** needs the PalmPDK ARM cross-gcc. The Mac copy at `/opt/PalmPDK` is
  **i386 → cannot run on Apple Silicon** (`bad CPU type`); build on a **Linux** box. The
  device binaries for offline RE are in `analysis/device/` (gitignored).

## Commands
- Build: `./build-ipks.sh` → `ipks/` (needs `patchelf`, **GNU ar**, and `BrowserServer.bin` — auto-fetched over novacom from a connected stock device).
- Diagnose on device: push `tls13-diag.sh`, `sh tls13-diag.sh` → look at the `VERDICT` line.
- Rebuild ipks on the Mac without the build tree: the Python re-wrap pattern used in history (extract members, repack GNU ar) — but prefer `build-ipks.sh`.

## Device access (novacom)
- novacom is at `/usr/local/bin` (PalmSDK). Device id: `topaz-linux`. It's a **dev tablet — anything goes**.
- **GOTCHA:** `novacom -- run file:///bin/sh -c '...'` **splits args on whitespace** (mangles multi-word commands). Instead: `novacom put file:///tmp/x.sh < local.sh` then `novacom -- run file:///bin/sh /tmp/x.sh`. Single commands with args are fine: `novacom -- run file:///usr/bin/md5sum /usr/bin/BrowserServer`.
- novacomd survives a dead UI → **always recoverable** even if a patch wedges boot.

## Critical gotchas (these bit us repeatedly — heed them)
- **App-Manager installs (Preware / WebOS Quick Install) ≠ `ipkg install`.** They unpack into the offline-root `/media/cryptofs/apps` and run a top-level **`pmPostInstall.script`** ar member, NOT the Debian `postinst`. So every package ships BOTH (the Debian postinst/prerm AND pmPostInstall.script/pmPreRemove.script as ar members) and the scripts **self-default `IPKG_OFFLINE_ROOT=/media/cryptofs/apps`**.
- **NEVER put a file backup in `/etc/event.d/`.** Upstart runs *every* file there as a job → a stray launcher backup becomes a duplicate, crash-looping `LunaSysMgr` that wedges boot. Backups go in `/var/luna/`. (This caused two "brick" scares that were NOT the TLS stack.)
- **GNU ar is required to build.** The pm-script ar members have long names; BSD ar (stock macOS `/usr/bin/ar`) writes an incompatible format the device may not read. `brew install binutils` on macOS. `build-ipks.sh` aborts if GNU ar is missing.
- **`/usr/bin/curl` default CA path** doesn't exist on-device → the curl wrapper sets `CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`. A **current CA bundle** (e.g. `com.palm.rootcertsupdate`) is required for cert validation everywhere.
- **`luna-tls13` requires `browser-tls13`'s `/usr/lib/ssl11`** (its postinst refuses to patch otherwise → can't brick on wrong order). On removal, take `luna-tls13` out **before** `browser-tls13`.

## Key facts / values
- Stock `BrowserServer` md5 `0786bdf698220aa82a90838e30355c9f`; RPATH'd build `a56bf4febbb961ce5249ed78caa0bf33`.
- `libWebKitLuna` hardcodes `ssl->ctx`@`0xD8`, `X509_STORE_CTX->cert`@`0x8`; the bundled OpenSSL relocates those + `libssl_compat.so` bridges the rest.
- Recovery from a wedged UI: `mount -o remount,rw / ; cp /var/luna/LunaSysMgr.tls13-orig /etc/event.d/LunaSysMgr ; reboot` (over novacom).
- webos-mcp server has webOS platform knowledge (resources under `webos://knowledge/...`) — consult `tls-and-networking`, `system-internals`, `gotchas`.

## Git
- `origin` = the fork (codepoet80), `upstream` = Herrie82. Team works on `main` (no feature branches). PR: `gh pr create --repo Herrie82/OpenSSL-legacyWebOS --base main --head codepoet80:main`.
- `BrowserServer.bin` and `ipks-backup/` are gitignored (build artifact / local backup).
