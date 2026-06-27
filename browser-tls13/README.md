# Browser TLS 1.3 — process-private OpenSSL 1.1 for BrowserServer

Goal: get the webOS TouchPad **browser** onto TLS 1.3 **without** the system-wide
OpenSSL swap that broke boot before.

## Why this works where the old `package/install.sh` didn't

The old script symlinked `libssl.so.0.9.8 → libssl.so.1.1` system-wide and put the
compat shim in `/etc/ld.so.preload` (every process). That forced **all 16** direct
OpenSSL consumers onto 1.1 at once — including `wpa_supplicant`, `vpnagentd`, `node`,
`keymanager`, `libpalmsocket` — several of which dereference now-opaque 0.9.8 structs
directly and crash, cascading to FD exhaustion and boot failure.

This approach moves **only the browser process**. Confirmed: the BrowserServer process
pulls 0.9.8 from exactly four places — `BrowserServer` (exe), `libWebKitLuna.so`,
`libPmCertificateMgr.so`, `libcurl.so.4`. All four use **function-based** OpenSSL APIs
(no opaque-struct offset access, no stack-allocated EVP), so they can be `patchelf`'d
onto 1.1 instead of recompiled. `libpalmsocket` is the only browser-adjacent lib that
truly needs source — and it is **not** in the browser process, so it's irrelevant here.

Isolation = a private `/usr/lib/ssl11/` injected via `LD_LIBRARY_PATH` for the browser
upstart job only. System `/usr/lib` is never modified → the other 14 consumers stay on
0.9.8 → boot is unaffected.

## Run order

```sh
# 0. Rebuild the compat shim FIRST (now includes sk_* forwarders):
arm-none-linux-gnueabi-gcc -shared -fPIC -o libssl_compat.so openssl_compat_shim.c \
    -I openssl-1.1.1w/include -L openssl-1.1.1w -lssl -lcrypto

# 1. HOST: assemble + patchelf the payload
browser-tls13/01-stage-host.sh
#    -> browser-tls13/ssl11-payload.tar.gz

# 2. DEVICE (root): install
scp browser-tls13/ssl11-payload.tar.gz root@<tp>:/tmp/
scp browser-tls13/0[23]-*-device.sh    root@<tp>:/tmp/
/tmp/02-install-device.sh /tmp/ssl11-payload.tar.gz

# rollback any time (full revert; system libs were never touched):
/tmp/03-rollback-device.sh
```

## What each browser binary needs from the shim

| Binary | OpenSSL use | Resolves via |
|---|---|---|
| `libcurl.so.4` (4.8.0) | full TLS engine | native 1.1 (already rebuilt) |
| `libWebKitLuna.so` | accessors, `MD5_*`/`SHA1`, `sk_num`/`sk_value` | 1.1 + shim `sk_*` |
| `BrowserServer` | init fns, `X509_cmp/free`, `PEM_read_X509` | 1.1 + shim init no-ops |
| `libPmCertificateMgr.so` | `PEM_*`/`d2i_*`/`X509_STORE_*`/`PKCS12_*`, `sk_*` | 1.1 + shim `sk_*` |

EVP shim is **not** needed in the browser process (no stack-allocated EVP contexts here).
Only `libssl_compat.so` is `LD_PRELOAD`ed.

## Known gotchas (handled)

- **`sk_*` renamed → `OPENSSL_sk_*` in 1.1** — restored by the new forwarders in
  `openssl_compat_shim.c`. `01-stage-host.sh` refuses to run if the shim doesn't export `sk_num`.
- **`X509_NAME_hash` changed MD5→SHA1** — `02-install-device.sh` re-hashes
  `/var/ssl/trustedcerts` (the CApath your `openssl-1.1.1w-palm.patch` hardcodes in
  `SSL_CTX_new`). Server-cert trust also flows through curl's `CAINFO` Mozilla bundle,
  so this only affects the legacy CApath.
- **`CRYPTO_free` 1-arg vs 3-arg** — benign (extra registers ignored in a release build).

## Verify

```sh
PID=$(pidof BrowserServer)
grep -E 'ssl11|libssl|libcrypto|libcurl' /proc/$PID/maps
# expect libssl.so.1.1 / libcrypto.so.1.1 / ssl11/libcurl.so.4.8.0 — and NO 0.9.8
```
Then load `https://www.cloudflare.com/` and `https://tls-v1-3.badssl.com:1013/`.
Sanity-check Wi-Fi/VPN still work (proves the isolation held).
