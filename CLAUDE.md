# CLAUDE.md — working in this repo

Modern TLS 1.2/1.3 (OpenSSL 1.1.1w + curl 7.88.1) for the 2011 HP TouchPad
(webOS 3.0.5, stock OpenSSL 0.9.8). Four ipks put a process-private stack in
`/usr/lib/ssl11` and wire the browser, the apps, and the CLI into it. Full story:
[`README.md`](README.md). Build/maintainer details: [`BUILDING.md`](BUILDING.md).

## The four packages (install order)
1. `browser-tls13` — RPATH'd `/usr/bin/BrowserServer` → stock browser on TLS 1.3. **Ships `/usr/lib/ssl11`; install first.**
2. `luna-tls13` — patches the `LunaSysMgr` upstart launcher → app WebKit (Mojo/Enyo XHR) on TLS 1.3, **+ `LD_BIND_NOW=1` (v1.1.0) so HTML5 streaming media plays** (see Key facts). **Needs #1; reboot after.**
3. `curl-tls13` — modern `/usr/bin/curl11` + `/usr/bin/curl` (stock backed up).
4. `ntpdate-sync` — NTP clock sync.

## Mail TLS — `mail-tls13` (5th package; **EAS + IMAP + SMTP all working & hardware-proven**, v1.3.0)
Goal: the stock Email app's native transports `mojomail-{eas,imap,pop,smtp}` reach modern
TLS so accounts like Zoho (`msync.zoho.com`, EAS) and Fastmail (IMAP/SMTP) sync again. Full
story in [`BUILDING.md`](BUILDING.md); deep notes in the `mail-eas-WORKING` and
`mail-imap-smtp-WORKING` auto-memories.
**Proven on hardware (v1.3.0):** EAS (Zoho: Mail/Contacts/Calendar/Tasks, TLS 1.3, no proxy)
AND IMAP+SMTP (Fastmail, TLS 1.3) all validate + sync.
- **Architecture:** `com.palm.app.email` is just UI → delegates to `palm://com.palm.eas/`
  etc. TLS happens in the native transports: **EAS via libcurl** (`libemail-common`'s
  `glibcurl`, multi interface; its `CurlSSLVerifier` adds a verify callback but sets NO CA
  path — it trusts **libcurl's built-in default bundle**), **IMAP/POP/SMTP via `libpalmsocket`**
  (direct OpenSSL, `SSLv23_method`; loads `/var/ssl/certs` + `set_default_verify_paths`).
  Launchers are the four D-Bus `*.service` files in `/usr/share/dbus-1/system-services/`;
  reload edits with **`ls-control scan-services`** (no UI bounce). Backups go in `/var/luna`.
- **Two dead ends proven on hardware** (don't repeat): (a) ssl11's libcurl 7.88.1 → SIGSEGV
  in `curl_multi_remove_handle` (glibcurl was built for curl 7.21.7+c-ares); (b) STOCK libcurl
  7.21.7 on ssl11 OpenSSL → TLS 1.3 ok then SIGSEGV inspecting the X509 cert.
- **The working fix (EAS, v1.2.0):** ship into `/usr/lib/ssl11mail` (and point the four
  launchers there): (1) a purpose-built **libcurl 7.61.1** `--enable-ares`, compiled vs
  OpenSSL 1.1 headers, **and `--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt`** (libcurl
  ignores the `CURL_CA_BUNDLE` *env* — only the curl CLI reads it — so the bundle MUST be
  baked in or EAS certs read as untrusted); (2) mail's **OWN `libssl_compat.so`** (a real
  file, NOT a symlink to ssl11's) — a superset adding **`CONF_modules_free`** (libpalmsocket)
  and **`SSL_CTX_get_ex_new_index`** (libemail-common), both 1.1 macros that the 0.9.8-built
  mail libs import as functions; unresolved → `exit(127)` after `SSL_CTX_new`, before any
  ClientHello. So mail-tls13 is **self-contained for the shim and never requires re-issuing
  browser-tls13** (it still *depends* on browser-tls13 being installed for ssl11's OpenSSL).
- **IMAP/SMTP fixes, both NON-TLS — the TLS layer was already fine** (libpalmsocket's CA store
  = `/var/ssl/certs` + `set_default_verify_paths` honoring the launcher's `SSL_CERT_FILE`
  verifies modern certs fine):
  - **(a) `LD_BIND_NOW=1`** on all four launchers (in `mail-tls13` v1.3.x) — with lazy binding
    the transports intermittently SIGSEGV in the glibc-2.8 dynamic linker
    (`do_lookup_x`/`check_match`) while first-resolving a PLT symbol across the shim + 0.9.8→1.1
    aliased OpenSSL (hit on SMTP); eager binding fixes it. (A launch-env change, not a mojomail
    binary change.)
  - **(b) mojomail-imap 1-byte patch** `~A`→`AA` (0x7e→0x41 at file offset **991784**): mojomail
    hard-codes a `~`-leading IMAP tag (`ImapRequestManager: ss << "~A" << id`), which strict
    servers (Fastmail) reject with an UNTAGGED `* BAD` that mojomail can't match → 30s hang
    (err 3099). **Shipped as a SEPARATE, optional package `org.webosinternals.mojomail-imap-tagfix`**
    (split out of mail-tls13 so it's take-or-leave and won't collide with other mojomail
    patches — it modifies a stock binary). Its postinst md5-guards the stock binary
    (`9f6489…`→`78956f…`), patches a same-fs temp copy + `mv` (in-place `dd` fails ETXTBSY on
    the running binary), backs up to `/var/luna/mojomail-imap.tagfix-orig`; prerm restores. The
    one and only mojomail-binary change — see `mojomail-changes.md`.
- **Build needs** `curl-mail/lib/.libs/libcurl.so.4.*` AND `libssl_compat.so` (build the shim
  from `openssl_compat_shim.c`); else mail is SKIPped/errors. Validate with `mail-tls13-diag.sh`.
- **Build host:** needs the PalmPDK ARM cross-gcc (`/opt/PalmPDK/arm-gcc`, gcc-4.3.3, i386 →
  **Linux box only**, not Apple Silicon). Device binaries for offline RE in `analysis/device/`
  (gitignored) — they're **not stripped**, so `objdump`/`nm` give named functions.

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
- **HTML5 streaming media (Pandora/Plex/drPodder) needs `LD_BIND_NOW=1` on the LunaSysMgr launcher** (added by `luna-tls13` ≥ v1.1.0; same lazy-binding class as the mail transports above). Without it, the `media-pipeline` worker that `WebAppMgr` **fork+execs** — inheriting the ssl11 env — SIGSEGVs in the glibc-2.8 dynamic linker while first (lazy) binding a PLT symbol across the 0.9.8→1.1 shim, **dying before `gst_init`, silently (no PmLog line, no crash report), on the network startup path only** (local `file://` media was unaffected → "Music plays, Pandora spins forever"). Proven NOT to be: gstreamer/TLS (`souphttpsrc`→`libsoup`→**gnutls** works fine under the stack; Pandora audio is plain http anyway), libcurl (worker links none), symbol collision (libcrypto.so.1.1 ∩ libgcrypt/libgnutls = 0), OpenSSL fork-safety (the worker is fork+EXEC, not fork-only), or nizovn. **No wrapper/env-scrub fix is possible** — the worker's LS2 role is keyed to the exe path `/usr/bin/media-pipeline` (re-exec of any other name → `-1027 Invalid permissions`), so the launcher **env** is the only lever. To debug the *real* worker (wrappers break its LS2 role): add `GST_DEBUG`+`GST_DEBUG_FILE=/media/internal/…` to the launcher env (not a wrapper), reboot, read the trace — empty for the network worker = dies before `gst_init`.

## Git
- `origin` = the fork (codepoet80), `upstream` = Herrie82. Team works on `main` (no feature branches). PR: `gh pr create --repo Herrie82/OpenSSL-legacyWebOS --base main --head codepoet80:main`.
- `BrowserServer.bin` and `ipks-backup/` are gitignored (build artifact / local backup).
