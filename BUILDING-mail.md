# Building `mail-tls13` — modern TLS for the webOS mail client

This is the maintainer recipe for the **mail** package (`org.webosinternals.mail-tls13`),
which routes the native mail transports (`mojomail-eas` / `-imap` / `-pop` / `-smtp`)
through the OpenSSL 1.1.1w stack so the stock Email app can sync Exchange ActiveSync /
IMAP / POP / SMTP accounts on modern TLS 1.2/1.3 servers (Zoho, Gmail, …).

Unlike the other four packages, mail-tls13 needs **one cross-compiled artifact you must
build first**: a purpose-built `libcurl`. Everything else (packaging, the `.service`
patches, the diagnostic) is already wired in `build-ipks.sh` + `mail-tls13-diag.sh`.

---

## Why a custom libcurl (read this first — it's the whole problem)

The mail transports do their HTTPS through **libcurl** (EAS) and **libpalmsocket** (the
line protocols). The stock device libs are `libcurl 7.21.7` + `libssl/libcrypto 0.9.8`,
which can't do TLS 1.2. We proved two dead ends on-device (see `analysis/device/` and the
`mail-tls-eas` project memory):

1. **Point mojomail at ssl11's libcurl 7.88.1** → `SIGSEGV` in `curl_multi_remove_handle`.
   The mojomail glue (`libemail-common`'s `glibcurl`, glib-mainloop + curl *multi*
   interface, built against curl **7.21.7 with c-ares**) is incompatible with the 11-years-
   newer 7.88.1 (no c-ares, different multi/resolver internals).

2. **Keep stock libcurl 7.21.7, redirect only its OpenSSL to ssl11** → the TLS 1.3
   handshake *succeeds* (`SSL connection using TLS_AES_128_GCM_SHA256`) but then `SIGSEGV`
   the moment libcurl inspects the server X509 cert. ssl11's OpenSSL was only *partially*
   offset-relocated (`ssl->ctx@0xD8`, `X509_STORE_CTX->cert@0x8`) for `libWebKitLuna`;
   libcurl 7.21.7's broader X509 field access hits the wrong offsets.

The fix has to satisfy **both** constraints at once. A libcurl that is:

- **compiled against OpenSSL 1.1 headers** → uses 1.1 accessors, no hardcoded 0.9.8
  offsets, so it runs on ssl11's OpenSSL with zero struct issues (this is exactly why
  `curl11` / 7.88.1 works perfectly on ssl11 today); **and**
- **old enough** that its multi-interface + c-ares behavior still matches mojomail's
  `glibcurl` glue (so the teardown crash from dead-end #1 doesn't reappear).

That points at curl **~7.51–7.61**: 7.51.0 is the first release with OpenSSL 1.1.0
support, and the multi interface is still the classic select/`fdset` model `glibcurl`
expects. Build it `--enable-ares` to match the stock 7.21.7 configuration.

> This version window is a hypothesis backed by the crash analysis, not yet hardware-
> proven. Treat the first build as a **test-tablet** experiment and iterate (below).

---

## Prerequisites

### 1. The PalmPDK cross-toolchain (NOT the SDK)

Two different things install under `/opt`:

| Path | What it is | Has an ARM compiler? |
|---|---|---|
| `/opt/PalmSDK/0.2` | open webOS **SDK** — `novacom`, `palm-package`, JS tooling | **No** |
| `/opt/PalmPDK` | Palm **PDK** — native C/C++ cross-toolchain | **Yes** |

You need the **PDK**. The stock ssl11 `curl-7.88.1` was built with it (per
`curl-7.88.1/config.log`):

```
/opt/PalmPDK/arm-gcc/bin/arm-none-linux-gnueabi-gcc   (GCC 4.3.3)
--with-sysroot=/opt/PalmPDK/arm-gcc/sysroot/          (glibc 2.8)
```

The TouchPad runs **glibc 2.8** (`/lib/libc-2.8.so`) and **armv7**, so the PDK's
gcc-4.3.3 + 2.8 sysroot is the safe target — a modern Linaro/crosstool toolchain may
emit references to glibc symbols newer than 2.8 that don't exist on-device. If you only
have the SDK, get the PDK: the old HP "PDK" installer placed it at `/opt/PalmPDK` on both
macOS and Linux; the open webOS build bits at <https://github.com/openwebos> (and the
`build-desktop` / cross recipes there) are an alternative source for an armv7/glibc-2.8
sysroot if the original PDK is unavailable. Herrie's box already has `/opt/PalmPDK`.

> **The Apple-Silicon Mac in this checkout cannot run the toolchain.** Even with the old
> 32-bit Mac PalmPDK copied to `/opt/PalmPDK`, its `arm-none-linux-gnueabi-gcc` is a
> **Mach-O i386** binary; on an M-series Mac (arm64) it fails with `bad CPU type in
> executable` (macOS has no 32-bit support; Rosetta 2 doesn't do i386). So the libcurl
> build **must run on a Linux box** — Herrie's host, or any Linux with a webOS-compatible
> armv7/glibc-2.8 cross-gcc. The Mac's `/opt/PalmPDK/arm-gcc/sysroot` + `/opt/PalmPDK/include`
> are still useful as *files* (copy them to the Linux box to use as `--sysroot`/headers if
> your Linux toolchain lacks a 2.8 sysroot). A Linux PalmPDK puts the same gcc-4.3.3 at
> `/opt/PalmPDK/arm-gcc/bin`.

### 2. OpenSSL 1.1.1w (already in the repo)

`openssl-1.1.1w/` ships the prebuilt `libssl.so.1.1` / `libcrypto.so.1.1` **and** the
headers under `openssl-1.1.1w/include`. Link/compile the new curl against this tree —
the same one the device's ssl11 came from, so the ABI matches exactly.

### 3. c-ares

Stock `mojomail` uses c-ares (async DNS); the device already ships
`/usr/lib/libcares.so.2.0.0` (soname `libcares.so.2`). Our new libcurl just needs to
**link `-lcares` at build time and resolve `libcares.so.2` at runtime from `/usr/lib`** —
the c-ares ABI (soname 2) is stable, so the device's copy satisfies it. You only need
c-ares *headers* + a link target at build time (Step 1 below).

---

## Build steps (on the PDK host)

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

Easiest is to build a matching c-ares from source (use a 1.7.x release — contemporary
with the device's, ABI-compatible). At runtime the device's `libcares.so.2` is used; this
build is only to satisfy the compiler/linker:

```sh
curl -LO https://github.com/c-ares/c-ares/releases/download/cares-1_7_5/c-ares-1.7.5.tar.gz
tar xf c-ares-1.7.5.tar.gz && cd c-ares-1.7.5
./configure --host=$CROSS --prefix=$PWD/_install --disable-static
make -j4 && make install
export CARES=$PWD/_install        # has include/ares.h and lib/libcares.so*
cd ..
```

(Alternative: copy the device's `analysis/device/`-style `libcares.so.2.0.0` as the link
target and grab the matching `ares.h` — but building from source is cleaner.)

### Step 2 — build the candidate libcurl

Start with **7.61.1** (adjust the URL for other candidates):

```sh
curl -LO https://curl.se/download/curl-7.61.1.tar.gz
tar xf curl-7.61.1.tar.gz && cd curl-7.61.1

./configure \
  --host=$CROSS \
  --with-ssl=$OSSL \
  --enable-ares=$CARES \
  --disable-static \
  --without-brotli --without-zstd --without-libpsl --without-librtmp \
  --disable-ldap --disable-ldaps \
  CC=$CC \
  CPPFLAGS="-I$OSSL/include -I$CARES/include -I$PDK/include" \
  LDFLAGS="-L$OSSL -L$CARES/lib -L$PDK/device/lib" \
  LIBS="-lssl -lcrypto -lcares -ldl -lpthread"

make -j4
ls -l lib/.libs/libcurl.so*       # -> libcurl.so.4.x.y  (the artifact you want)
```

Notes:
- `--with-ssl=$OSSL` (curl ≤7.76 spelling; 7.77+ also accepts `--with-openssl`).
- `--enable-ares=$CARES` is what keeps mojomail's `glibcurl` glue happy. If a build still
  crashes in teardown on-device, try **without** `--enable-ares` and/or an older curl —
  see iteration below.
- Don't install system-wide; we only want `lib/.libs/libcurl.so.4.x.y`.

### Step 3 — sanity-check the artifact

```sh
$CROSS-readelf -d lib/.libs/libcurl.so.4.* | grep -E 'NEEDED|SONAME'
```

Expect `SONAME libcurl.so.4` and `NEEDED` entries for **`libssl.so.1.1`,
`libcrypto.so.1.1`, `libcares.so.2`** (plus libc/pthread/z). The 1.1 sonames are the
point — this libcurl loads ssl11's OpenSSL directly and never touches the 0.9.8 offsets
that crashed the stock one.

---

## Packaging it (`build-ipks.sh`)

Drop the built lib where the build expects it and rebuild:

```sh
mkdir -p curl-mail/lib/.libs
cp /path/to/curl-7.61.1/lib/.libs/libcurl.so.4.* curl-mail/lib/.libs/
./build-ipks.sh
```

`build-ipks.sh` ships this libcurl into the mail redirect dir **`/usr/lib/ssl11mail`** and
lays it out so mojomail uses *our* libcurl + ssl11 OpenSSL, while everything else (the
0.9.8-soname consumers like `libpalmsocket`) gets ssl11 OpenSSL via the aliases:

```
/usr/lib/ssl11mail/
  libcurl.so.4         -> libcurl.so.4.x.y      (OUR build; NEEDs libssl.so.1.1)
  libcurl.so.4.x.y                              (shipped in the ipk)
  libssl.so.1.1        -> /usr/lib/ssl11/libssl.so.1.1
  libcrypto.so.1.1     -> /usr/lib/ssl11/libcrypto.so.1.1
  libssl.so.0.9.8      -> /usr/lib/ssl11/libssl.so.1.1      (mojomail/libpalmsocket refs)
  libcrypto.so.0.9.8   -> /usr/lib/ssl11/libcrypto.so.1.1
  libssl_compat.so     -> /usr/lib/ssl11/libssl_compat.so
```

The four `.service` `Exec=` lines get prefixed with
`/usr/bin/env LD_LIBRARY_PATH=/usr/lib/ssl11mail LD_PRELOAD=/usr/lib/ssl11mail/libssl_compat.so CURL_CA_BUNDLE=… SSL_CERT_FILE=…`
(backups in `/var/luna`, reload via `ls-control scan-services`). Requires
`org.webosinternals.browser-tls13` (provides `/usr/lib/ssl11`). No reboot needed.

> If `curl-mail/lib/.libs/libcurl.so.4.*` is absent, the build skips mail-tls13 with a
> notice rather than shipping a known-broken (libcurl-less) package.

---

## Testing & iteration (test tablet, not a daily driver)

1. Install `browser-tls13` (if not already) + `mail-tls13`. No reboot needed, but a
   reboot is a fine extra check.
2. Push and run the diagnostic:
   ```sh
   novacom put file:///tmp/mail-tls13-diag.sh < mail-tls13-diag.sh
   novacom -- run file:///bin/sh /tmp/mail-tls13-diag.sh
   ```
   Look for the `VERDICT` line. It triggers a live EAS sync and checks for the libcurl
   crash, TLS/cert errors, and account error state.
3. **Success looks like:** `mojomail-eas` reaches a connected/`Sync`/`Ready` state, the
   Inbox folder's `lastSyncTime` advances, new mail appears, and the account `error` stays
   `null`. (A still-failing login loops `ValidateUser → PendingLogin → reset` with no
   socket activity — that's the symptom we saw with the stock-libcurl attempt.)
4. **If EAS still crashes/loops**, iterate the libcurl: try `7.65.3`, then `7.51.0`; try
   toggling `--enable-ares`. Re-run the diag each time. Capture detail by temporarily
   bumping the eas log level to `debug` in `com.palm.eas.service` and watching
   `/var/log/messages` (look for `libpalmsocket`, curl, HTTP, and any `received 11`).

### IMAP / POP / SMTP — separate validation

EAS uses libcurl; the line protocols use **libpalmsocket** (which calls OpenSSL directly,
`SSLv23_method`). libpalmsocket is *also* a 0.9.8-built X509 consumer, so it carries the
same offset risk libcurl did. `luna-tls13` already runs another 0.9.8 X509 consumer
(`libWebKitLuna`) on ssl11 OpenSSL successfully, so libpalmsocket *may* be fine — but it's
unproven. Test an IMAP account once available; if libpalmsocket `SIGSEGV`s on the cert,
the remedy is to widen ssl11 OpenSSL's struct-offset relocation (the `libssl_compat.so` /
`openssl_compat_shim.c` + the offset patches in the `openssl-1.1.1w` build) to cover the
fields it reads — a separate task that also needs the PDK toolchain.

---

## Recovery (if a test goes sideways)

mail-tls13 only touches the four mail launchers + `/usr/lib/ssl11mail` — never boot paths.
Uninstall in Preware (runs `prerm`), or by hand over novacom:

```sh
for s in eas imap pop smtp; do
  cp -f /var/luna/com.palm.$s.service.tls13-orig \
        /usr/share/dbus-1/system-services/com.palm.$s.service
done
rm -rf /usr/lib/ssl11mail
/usr/bin/ls-control scan-services
killall mojomail-eas mojomail-imap mojomail-pop mojomail-smtp
```
