# Building the ipks

Developer/maintainer notes for building the four packages. End-user info and the
technical overview are in the [project README](README.md).

```sh
./build-ipks.sh        # outputs the four ipks into ipks/
```

Paths resolve relative to the script (the repo checkout), so it runs from wherever
you clone it. It **fails fast with a descriptive error** if a prerequisite is missing.

## Prerequisites

- **`patchelf`** — to RPATH `BrowserServer` (`apt-get install patchelf` / `brew install patchelf`).
- **GNU `ar`** (binutils) — the `pmPostInstall.script`/`pmPreRemove.script` ar members
  have long names; BSD `ar` (stock macOS) writes an incompatible long-name format the
  device's ipkg/appinstaller can't read. On macOS: `brew install binutils`. On Linux
  the system `ar` is already GNU. The script aborts with a hint if it can't find GNU ar.
- **`BrowserServer.bin`** — the stock 3.0.5 binary (md5 `0786bdf698220aa82a90838e30355c9f`)
  at the repo root. If absent, the script **auto-fetches it over `novacom` from a
  connected, factory/stock TouchPad** and verifies the md5. So either connect a
  freshly-reset TouchPad (novacom mode) or drop a known-stock `BrowserServer.bin` in
  the repo root. Aborts if no device is connected and the file is missing.
- Other inputs (`openssl-1.1.1w/`, `curl-7.88.1/`, `libssl_compat.so`, `ntpdate-sync`)
  are committed in the repo.

The build cleans only its own artifacts in `ipks/` (`*.ipk` + `_b_*` dirs); it leaves
the committed ipks' README alone.

## Packaging convention (why the postinsts look the way they do)

These install through the webOS **App-Manager** path (Preware "install file" / WebOS
Quick Install / App Catalog), which is *not* a plain `ipkg install`:

- It unpacks into the app offline-root **`/media/cryptofs/apps`** (via `ipkg -o`) and
  runs a top-level **`pmPostInstall.script`** ar member — **not** the Debian `postinst`.
- So every package ships its install logic as *both* a Debian `postinst`/`prerm`
  **and** `pmPostInstall.script`/`pmPreRemove.script` (the `pack()` function copies
  them and adds them as ar members), and the scripts **self-default
  `IPKG_OFFLINE_ROOT=/media/cryptofs/apps`** so they work on every path (App-Manager,
  Preware feed, plain `ipkg`).
- Data is laid out as a headless app under `./usr/palm/applications/<id>/files/…`; the
  postinst relocates `files/` into the live system.
- **ar member order:** `debian-binary, data.tar.gz, control.tar.gz,
  pmPostInstall.script, pmPreRemove.script` (GNU `//` long-name table — hence the
  GNU-ar requirement above).
- **Never leave a launcher backup inside `/etc/event.d/`** — upstart runs *every* file
  there as a job, so a stray backup becomes a duplicate, crash-looping `LunaSysMgr`
  that wedges boot. `luna-tls13` keeps its backup in `/var/luna/`.

## Repo layout

```
build-ipks.sh          build all four ipks (above)
tls13-diag.sh          on-device diagnostic (push + `sh tls13-diag.sh`; PASS/FAIL VERDICT)
ipks/                  built packages + slim install-order README
openssl-1.1.1w/        OpenSSL 1.1.1w tree (libssl.so.1.1, libcrypto.so.1.1; ssl->ctx @0xD8, cert @0x8)
curl-7.88.1/           curl 7.88.1 tree (libcurl.so.4.8.0, src/.libs/curl; --with-openssl --with-zlib)
libssl_compat.so       0.9.8->1.1 compat shim (sk_* forwarders, init no-ops)
openssl_compat_shim.c  shim source
ntpdate-sync           the upstart NTP job
BrowserServer.bin      stock 3.0.5 BrowserServer (not committed; auto-fetched at build time)
```

The packages are **unsigned** — sign with the webos-internals feed key before
publishing to the official feed.
