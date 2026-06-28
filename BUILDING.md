# Building the ipks

Developer/maintainer notes for building the packages. End-user info and the technical
overview are in the [project README](README.md). The single change this suite makes to a
stock mojomail binary ships in its own optional package and is documented separately in
[mojomail-changes.md](mojomail-changes.md).

```sh
./build-ipks.sh                 # build everything into ipks/
./build-ipks.sh mail            # build one or more
                                # (browser | luna | curl | ntp | mail | imaptagfix | all)
```

Paths resolve relative to the script (the repo checkout), so it runs from wherever you
clone it. It **fails fast with a descriptive error** if a prerequisite is missing. The
package selector lets you (re)build `mail` without a clean stock device attached — handy
because the browser package needs a stock `BrowserServer` and mail does not.

The packages: the four core TLS packages `browser-tls13`, `luna-tls13`, `curl-tls13`,
`ntpdate-sync`; the mail TLS package `mail-tls13` (its own large section below — it needs a
cross-compiled libcurl); and one **optional, standalone** package `mojomail-imap-tagfix` (a
one-byte mojomail-imap patch, kept separate so it can be taken or left independently).

## Prerequisites (all packages)

- **`patchelf`** — to RPATH `BrowserServer` (`apt-get install patchelf` / `brew install patchelf`).
  Only needed when building `browser`.
- **GNU `ar`** (binutils) — the `pmPostInstall.script`/`pmPreRemove.script` ar members
  have long names; BSD `ar` (stock macOS) writes an incompatible long-name format the
  device's ipkg/appinstaller can't read. On macOS: `brew install binutils`. On Linux
  the system `ar` is already GNU. The script aborts with a hint if it can't find GNU ar.
- **`BrowserServer.bin`** — the stock 3.0.5 binary (md5 `0786bdf698220aa82a90838e30355c9f`)
  at the repo root. If absent, the script **auto-fetches it over `novacom` from a
  connected, factory/stock TouchPad** and verifies the md5. Only needed when building
  `browser` (the selector skips this gate otherwise).
- Other inputs (`openssl-1.1.1w/`, `curl-7.88.1/`, `libssl_compat.so`, `ntpdate-sync`,
  and — for mail — `curl-mail/`) are committed in the repo.

**mail-tls13 needs more** — the PalmPDK ARM cross-toolchain and a c-ares link target to
(re)build its libcurl. Those are covered in the mail section. The committed
`curl-mail/lib/.libs/libcurl.so.4.5.0` means a normal `./build-ipks.sh` reproduces the
mail ipk without the toolchain; you only need the toolchain to change the libcurl.

The build cleans only its own artifacts in `ipks/` (`*.ipk` for a full build, `_b_*`
dirs); a selective rebuild keeps the other packages' ipks.

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
  that wedges boot. `luna-tls13` and `mail-tls13` keep their backups in `/var/luna/`.

The packages are **unsigned** — sign with the webos-internals feed key before publishing
to the official feed.

---

# The mail package — `mail-tls13`

Routes the native mail transports (`mojomail-eas` / `-imap` / `-pop` / `-smtp`) through the
OpenSSL 1.1.1w stack so the stock Email app syncs Exchange ActiveSync / IMAP / POP / SMTP
accounts on modern TLS 1.2/1.3 servers. **Hardware-proven (v1.3.0):** EAS (Zoho —
Mail/Contacts/Calendar/Tasks, TLS 1.3, no proxy) and IMAP+SMTP (Fastmail, TLS 1.3) all
validate and sync.

Unlike the other four packages, mail-tls13 needs **one cross-compiled artifact**: a
purpose-built `libcurl` (already committed at `curl-mail/lib/.libs/libcurl.so.4.5.0`, so you
only rebuild it to change the curl version). Everything else (packaging, the `.service`
patches, the diagnostic) is wired into `build-ipks.sh` + `mail-tls13-diag.sh`. (The IMAP-tag
mojomail patch is a *separate* package — see the [mojomail-imap-tagfix](#mojomail-imap-tagfix-optional-standalone)
section.)

## Why a custom libcurl (the core problem)

The mail transports do their HTTPS through **libcurl** (EAS, via `libemail-common`'s
`glibcurl`) and **libpalmsocket** (the IMAP/POP/SMTP line protocols). The stock device libs
are `libcurl 7.21.7` + `libssl/libcrypto 0.9.8`, which can't do TLS 1.2. Two dead ends were
proven on-device:

1. **Point mojomail at ssl11's libcurl 7.88.1** → `SIGSEGV` in `curl_multi_remove_handle`.
   The mojomail glue (`glibcurl`, glib-mainloop + curl *multi* interface, built against curl
   **7.21.7 with c-ares**) is incompatible with the 11-years-newer 7.88.1 (no c-ares,
   different multi/resolver internals).
2. **Keep stock libcurl 7.21.7, redirect only its OpenSSL to ssl11** → the TLS 1.3 handshake
   *succeeds* but then `SIGSEGV` the moment libcurl inspects the server X509 cert. ssl11's
   OpenSSL was only *partially* offset-relocated (`ssl->ctx@0xD8`, `X509_STORE_CTX->cert@0x8`)
   for `libWebKitLuna`; libcurl 7.21.7's broader X509 field access hits the wrong offsets.

The fix satisfies **both** constraints at once — a libcurl that is:

- **compiled against OpenSSL 1.1 headers** → uses 1.1 accessors, no hardcoded 0.9.8 offsets,
  so it runs on ssl11's OpenSSL with zero struct issues (exactly why `curl11` / 7.88.1 works
  on ssl11 today); **and**
- **old enough** that its multi-interface + c-ares behavior still matches mojomail's
  `glibcurl` glue (so the teardown crash from dead-end #1 doesn't reappear).

**curl 7.61.1** (`--enable-ares`, the classic select/`fdset` multi model) is the
hardware-proven choice. (7.51.0 is the first release with OpenSSL 1.1.0 support, so the
~7.51–7.61 window is the candidate range if you ever need to iterate.)

## Mail build prerequisites

### 1. The PalmPDK cross-toolchain (NOT the SDK)

Two different things install under `/opt`:

| Path | What it is | Has an ARM compiler? |
|---|---|---|
| `/opt/PalmSDK/0.2` | open webOS **SDK** — `novacom`, `palm-package`, JS tooling | **No** |
| `/opt/PalmPDK` | Palm **PDK** — native C/C++ cross-toolchain | **Yes** |

You need the **PDK** (`gcc-4.3.3`, glibc-2.8 sysroot):

```
/opt/PalmPDK/arm-gcc/bin/arm-none-linux-gnueabi-gcc   (GCC 4.3.3)
--with-sysroot=/opt/PalmPDK/arm-gcc/sysroot/          (glibc 2.8)
```

The TouchPad runs **glibc 2.8** and **armv7**, so the PDK's gcc-4.3.3 + 2.8 sysroot is the
safe target — a modern Linaro/crosstool toolchain may emit references to glibc symbols newer
than 2.8 that don't exist on-device.

> **An Apple-Silicon Mac cannot run the toolchain.** The Mac PalmPDK's
> `arm-none-linux-gnueabi-gcc` is a **Mach-O i386** binary; on arm64 macOS it fails with
> `bad CPU type in executable`. Build on a **Linux box** (the toolchain's `sysroot`/`include`
> are still useful as files to copy over). The same gcc-4.3.3 lives at
> `/opt/PalmPDK/arm-gcc/bin` on a Linux PalmPDK.

### 2. OpenSSL 1.1.1w (already in the repo)

`openssl-1.1.1w/` ships the prebuilt `libssl.so.1.1` / `libcrypto.so.1.1` **and** headers
under `openssl-1.1.1w/include`. Link/compile the new curl against this tree — the same one
the device's ssl11 came from, so the ABI matches exactly.

### 3. c-ares

Stock mojomail uses c-ares (async DNS); the device ships `/usr/lib/libcares.so.2.0.0` (soname
`libcares.so.2`). The new libcurl just needs to **link `-lcares` at build time and resolve
`libcares.so.2` at runtime from `/usr/lib`** — the soname-2 ABI is stable, so the device's
copy satisfies it. You only need c-ares *headers* + a link target at build time (Step 1).

## Building the libcurl (on the PDK host)

Set up the environment once:

```sh
export PDK=/opt/PalmPDK
export PATH="$PDK/arm-gcc/bin:$PATH"
export CROSS=arm-none-linux-gnueabi
export CC=$CROSS-gcc AR=$CROSS-ar RANLIB=$CROSS-ranlib
export SYSROOT=$PDK/arm-gcc/sysroot
export OSSL=/path/to/OpenSSL-legacyWebOS/openssl-1.1.1w   # this repo's tree
```

### Step 1 — c-ares headers + link lib

A clean way is to build a matching c-ares (1.7.x — contemporary with the device's). At
runtime the device's `libcares.so.2` is used; this build only satisfies the compiler/linker.
The c-ares *release* tarballs ship a `configure`; the GitHub *source* archive does not (no
autotools needed if you use a release). If you have no autotools, you can instead assemble a
link kit from the c-ares source headers + the device's own `libcares.so.2.0.0` as the link
target — note `ares_build.h.dist`'s generic-GCC branch only defines `CARES_SIZEOF_LONG` for
i386/x86_64/ppc, so add `|| defined(__arm__)` to that `#if` (else curl's configure dies
"c-ares library defective or too old"). Export `CARES` to point at the dir holding
`include/ares.h` + `lib/libcares.so*`.

### Step 2 — build the candidate libcurl

```sh
curl -LO https://curl.se/download/curl-7.61.1.tar.gz
tar xf curl-7.61.1.tar.gz && cd curl-7.61.1

./configure \
  --host=$CROSS \
  --with-ssl=$OSSL \
  --enable-ares=$CARES \
  --disable-static \
  --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
  --without-brotli --without-zstd --without-libpsl --without-librtmp \
  --disable-ldap --disable-ldaps \
  CC=$CC \
  CPPFLAGS="-I$OSSL/include -I$CARES/include -I$PDK/include" \
  LDFLAGS="-L$OSSL -L$CARES/lib -L$PDK/device/lib" \
  LIBS="-lssl -lcrypto -lcares -ldl -lpthread"

make -j4
ls -l lib/.libs/libcurl.so*       # -> libcurl.so.4.5.0  (the artifact you want)
```

> **`--with-ca-bundle` is REQUIRED, not optional.** `libemail-common`'s `CurlSSLVerifier`
> sets no CA path and trusts libcurl's *built-in* default bundle, and **libcurl ignores the
> `CURL_CA_BUNDLE` environment variable** (only the curl *CLI* reads it). Without the bundle
> baked in, EAS reaches the server but every cert reads as untrusted (`SSL_CERT_UNTRUSTED`).

Notes:
- `--with-ssl=$OSSL` (curl ≤7.76 spelling; 7.77+ also accepts `--with-openssl`).
- `--enable-ares=$CARES` keeps mojomail's `glibcurl` glue happy.
- Don't install system-wide; we only want `lib/.libs/libcurl.so.4.5.0`.

### Step 3 — sanity-check the artifact

```sh
$CROSS-readelf -d lib/.libs/libcurl.so.4.* | grep -E 'NEEDED|SONAME'
```

Expect `SONAME libcurl.so.4` and `NEEDED` entries for **`libssl.so.1.1`, `libcrypto.so.1.1`,
`libcares.so.2`** (plus libc/pthread/z). The 1.1 sonames are the point — this libcurl loads
ssl11's OpenSSL directly and never touches the 0.9.8 offsets that crashed the stock one.

## Packaging the mail ipk (`build-ipks.sh`)

Drop the built lib where the build expects it and rebuild (it's already committed, so this is
only when changing curl):

```sh
mkdir -p curl-mail/lib/.libs
cp /path/to/curl-7.61.1/lib/.libs/libcurl.so.4.* curl-mail/lib/.libs/
./build-ipks.sh mail
```

`build-ipks.sh` ships this libcurl into the mail redirect dir **`/usr/lib/ssl11mail`** and
lays it out so mojomail uses *our* libcurl + ssl11 OpenSSL, while the 0.9.8-soname consumers
(`libpalmsocket`, `libemail-common`) get ssl11 OpenSSL via aliases:

```
/usr/lib/ssl11mail/
  libcurl.so.4         -> libcurl.so.4.5.0      (OUR build; NEEDs libssl.so.1.1)
  libcurl.so.4.5.0                              (shipped in the ipk)
  libssl.so.1.1        -> /usr/lib/ssl11/libssl.so.1.1
  libcrypto.so.1.1     -> /usr/lib/ssl11/libcrypto.so.1.1
  libssl.so.0.9.8      -> /usr/lib/ssl11/libssl.so.1.1      (mojomail/libpalmsocket refs)
  libcrypto.so.0.9.8   -> /usr/lib/ssl11/libcrypto.so.1.1
  libssl_compat.so                             (REAL copy, shipped in the ipk -- NOT a
                                                symlink to ssl11's; a superset, below)
```

**Why mail ships its OWN `libssl_compat.so` (a real file, not a symlink to ssl11's):** the
0.9.8-built mail libs import two symbols that are *macros* in OpenSSL 1.1 (so absent from
`libssl.so.1.1`) and that the browser's shim doesn't carry — `CONF_modules_free`
(`libpalmsocket`) and `SSL_CTX_get_ex_new_index` (`libemail-common`). Unresolved, the EAS
validation worker `exit(127)`s right after `SSL_CTX_new`, before any TLS ClientHello (UI:
"Message status unknown"). They're added to `openssl_compat_shim.c` (a harmless superset), so
`mail-tls13` is **self-contained for the shim and never requires re-issuing `browser-tls13`**
— it still *depends* on browser-tls13 being installed (for ssl11's OpenSSL `.so`s). The build
ships the prebuilt `libssl_compat.so` from the repo root; if you edit `openssl_compat_shim.c`,
rebuild the `.so` (one-liner in the shim's header comment) and commit it.

The four `.service` `Exec=` lines get prefixed with
`/usr/bin/env LD_BIND_NOW=1 LD_LIBRARY_PATH=/usr/lib/ssl11mail LD_PRELOAD=/usr/lib/ssl11mail/libssl_compat.so CURL_CA_BUNDLE=… SSL_CERT_FILE=…`
(backups in `/var/luna`, reload via `ls-control scan-services`). Requires
`org.webosinternals.browser-tls13` (provides `/usr/lib/ssl11`). No reboot needed.

mail-tls13 does **not** modify any mojomail binary (that's the separate `mojomail-imap-tagfix`
package, below).

> If `curl-mail/lib/.libs/libcurl.so.4.*` or `libssl_compat.so` is absent, the build skips
> (or errors on) mail-tls13 rather than shipping a broken package.

## Two non-TLS fixes for IMAP/SMTP (v1.3.x)

EAS goes through libcurl; the line protocols use **libpalmsocket** (direct OpenSSL,
`SSLv23_method`). libpalmsocket's TLS + cert verification work fine on ssl11 — the feared
X509-offset SIGSEGV never materialised; it verifies modern certs via its own CA setup
(`/var/ssl/certs` + `SSL_CTX_set_default_verify_paths`, which honors the launcher's
`SSL_CERT_FILE`). The two things that DID block IMAP/SMTP were both **non-TLS**:

1. **Intermittent dynamic-linker SIGSEGV** (hit on SMTP). With lazy binding the transports
   crash in glibc-2.8 `ld.so` (`do_lookup_x`/`check_match`) the first time they resolve a PLT
   symbol across our shim + the 0.9.8→1.1 aliased OpenSSL. Fix: **`LD_BIND_NOW=1`** on all
   four launchers (eager binding resolves everything at exec). It's in the launcher `PFX`,
   part of **mail-tls13** (a launch-env change, not a mojomail binary change).
2. **mojomail's `~A` IMAP tag** — a one-byte `mojomail-imap` binary patch, shipped as the
   separate optional package below.

## mojomail-imap-tagfix (optional, standalone)

`org.webosinternals.mojomail-imap-tagfix` is a tiny package whose **only** job is the one-byte
`mojomail-imap` patch (`~A`→`AA` IMAP command tag, `0x7e`→`0x41` at file offset `991784`). It
exists separately from `mail-tls13` on purpose: it modifies a **stock mojomail binary**, which
is a different risk class than the TLS libs/launchers, may be unnecessary for users on lenient
servers, and could collide with other people's mojomail patches. Take it or leave it.

- **No payload, no dependencies.** The postinst md5-guards the stock 3.0.5 binary
  (`9f6489…`→`78956f…`), patches a same-fs temp copy then `mv`s it over (in-place `dd` fails
  `ETXTBSY` on the running binary), and backs up to `/var/luna/mojomail-imap.tagfix-orig`; the
  prerm restores it. If the binary's md5 is unrecognized it does nothing.
- Build it with `./build-ipks.sh imaptagfix` (or as part of `./build-ipks.sh`).
- Full exact-bytes record: [mojomail-changes.md](mojomail-changes.md).

---

# Testing & recovery

## Diagnostics

- **The four-package stack:** push and run `tls13-diag.sh`
  (`novacom -- run file:///bin/sh /tmp/tls13-diag.sh`) → read the `VERDICT` line.
- **Mail:** push and run `mail-tls13-diag.sh` the same way. It triggers a live EAS sync and
  checks for the libcurl crash, TLS/cert errors, and account error state. Success: a transport
  reaches a connected/`Ready` state, the Inbox `lastSyncTime` advances, and the account
  `error` stays `null`. To capture protocol-level detail, bump a transport's log level to
  `debug` in its `com.palm.<svc>.service` and watch `/var/log/messages`.

## Recovery (mail)

mail-tls13 only touches the four mail launchers, `/usr/lib/ssl11mail`, and (reversibly)
`/usr/bin/mojomail-imap` — never boot paths. Uninstall in Preware (runs `prerm`), or by hand
over novacom:

```sh
for s in eas imap pop smtp; do
  cp -f /var/luna/com.palm.$s.service.tls13-orig \
        /usr/share/dbus-1/system-services/com.palm.$s.service
done
[ -f /var/luna/mojomail-imap.tls13-orig ] && cp -f /var/luna/mojomail-imap.tls13-orig /usr/bin/mojomail-imap
rm -rf /usr/lib/ssl11mail
/usr/bin/ls-control scan-services
killall mojomail-eas mojomail-imap mojomail-pop mojomail-smtp
```

Recovery for the browser/luna stack (if the UI ever fails to boot) is in the
[project README](README.md).

---

## Repo layout

```
build-ipks.sh          build the ipks ([browser|luna|curl|ntp|mail|imaptagfix|all]; default all)
tls13-diag.sh          on-device diagnostic for the four-package stack (PASS/FAIL VERDICT)
mail-tls13-diag.sh     on-device diagnostic for mail-tls13
mojomail-changes.md    the single 1-byte change to a stock mojomail binary (the imaptagfix package)
ipks/                  built packages + slim install-order README
openssl-1.1.1w/        OpenSSL 1.1.1w tree (libssl.so.1.1, libcrypto.so.1.1; ssl->ctx @0xD8, cert @0x8)
curl-7.88.1/           curl 7.88.1 tree for browser/curl packages (libcurl.so.4.8.0, src/.libs/curl)
curl-mail/lib/.libs/   curl 7.61.1 libcurl for mail (vs OpenSSL 1.1 headers, --enable-ares, --with-ca-bundle)
libssl_compat.so       0.9.8->1.1 compat shim (sk_* forwarders, init no-ops, + the two mail symbols)
openssl_compat_shim.c  shim source
ntpdate-sync           the upstart NTP job
BrowserServer.bin      stock 3.0.5 BrowserServer (not committed; auto-fetched at build time)
```
