#!/bin/bash
#
# 01-stage-host.sh  --  Build the process-private OpenSSL 1.1 payload for the
#                       webOS TouchPad BrowserServer.  Runs on the BUILD HOST.
#
# APPROACH (validated on-device 2026-06-27): symlink-redirect, NOT patchelf.
#   patchelf 0.18 corrupts the segment alignment of the 12.8 MB libWebKitLuna.so
#   ("ELF load command address/offset not properly aligned" -> BrowserServer
#   won't even load).  Instead we leave ALL device binaries byte-for-byte
#   unmodified and put the OpenSSL 1.1 libs in a private /usr/lib/ssl11 dir under
#   BOTH their real 1.1 sonames AND the legacy 0.9.8 filenames (as symlinks).
#   The browser upstart job adds ssl11 to LD_LIBRARY_PATH, so the unmodified
#   BrowserServer / libWebKitLuna / libPmCertificateMgr (which NEED libssl.so.0.9.8)
#   resolve that name to the 1.1 lib, while the new libcurl (which NEEDs
#   libssl.so.1.1) resolves the same physical file.  glibc dedups by inode, so
#   only ONE copy of OpenSSL 1.1 loads -> no double-load, no SSL_CTX ABI split.
#
#   Nothing system-wide changes; the other 14 legacy OpenSSL consumers keep using
#   the untouched /usr/lib/libssl.so.0.9.8.
#
# Output: ssl11-payload.tar.gz  (copy to device, then run 02-install-device.sh)
#
set -euo pipefail

BASE="${BASE:-/home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update}"

LIBSSL11="${LIBSSL11:-$BASE/openssl-1.1.1w/libssl.so.1.1}"
LIBCRYPTO11="${LIBCRYPTO11:-$BASE/openssl-1.1.1w/libcrypto.so.1.1}"
LIBCURL48="${LIBCURL48:-}"                         # auto-detected if empty
LIBCOMPAT="${LIBCOMPAT:-$BASE/libssl_compat.so}"   # REBUILD first (sk_* forwarders)

STAGE="${STAGE:-$BASE/browser-tls13/_stage}"
OUT="${OUT:-$BASE/browser-tls13/ssl11-payload.tar.gz}"

command -v tar >/dev/null || { echo "ERROR: need tar"; exit 1; }
[ -z "$LIBCURL48" ] && LIBCURL48="$(find "$BASE" -name 'libcurl.so.4.8.0' -not -path '*/_stage/*' 2>/dev/null | head -1)"

echo "== validating inputs =="
fail=0
for f in "$LIBSSL11" "$LIBCRYPTO11" "$LIBCURL48" "$LIBCOMPAT"; do
    if [ -f "$f" ]; then echo "  OK   $f"; else echo "  MISS $f"; fail=1; fi
done
[ "$fail" = 0 ] || { echo "ERROR: fix MISS paths (env-override) and re-run."; exit 1; }

# the compat shim MUST export the sk_* forwarders, or libWebKitLuna /
# libPmCertificateMgr fail to resolve sk_num/sk_value against 1.1.
if ! readelf -W --dyn-syms "$LIBCOMPAT" 2>/dev/null | awk '$7!="UND"{print $8}' | grep -qx sk_num; then
    echo "ERROR: $LIBCOMPAT does not export sk_num. Rebuild the shim:"
    echo "  arm-none-linux-gnueabi-gcc -shared -fPIC -o libssl_compat.so openssl_compat_shim.c \\"
    echo "      -I$BASE/openssl-1.1.1w/include -L$BASE/openssl-1.1.1w -lssl -lcrypto"
    exit 1
fi

echo "== assembling private ssl11/ tree (symlink-redirect, no patchelf) =="
rm -rf "$STAGE"
L="$STAGE/usr/lib/ssl11"
mkdir -p "$L"

cp -v "$LIBSSL11"    "$L/libssl.so.1.1"
cp -v "$LIBCRYPTO11" "$L/libcrypto.so.1.1"
cp -v "$LIBCOMPAT"   "$L/libssl_compat.so"
cp -v "$LIBCURL48"   "$L/libcurl.so.4.8.0"

# legacy-name symlinks: the unmodified 0.9.8-linked browser binaries find these
ln -sf libssl.so.1.1    "$L/libssl.so.0.9.8"
ln -sf libcrypto.so.1.1 "$L/libcrypto.so.0.9.8"
# soname the new libcurl is requested by (libWebKitLuna NEEDs libcurl.so.4)
ln -sf libcurl.so.4.8.0 "$L/libcurl.so.4"

echo "== staged tree =="
ls -la "$L"

echo "== packing $OUT =="
# plain tar PRESERVES the symlinks (do NOT use -h, which would dereference them)
tar czf "$OUT" -C "$STAGE" usr
echo "  payload symlinks:"; tar tzvf "$OUT" | grep -- '->' | sed 's/^/    /'
echo
echo "DONE. Copy to device and run 02-install-device.sh:"
echo "  scp '$OUT' root@<touchpad>:/tmp/ssl11-payload.tar.gz"
echo
echo "REMINDER: the browser validates server certs via CURLOPT_CAINFO ="
echo "  /etc/ssl/certs/ca-certificates.crt -- make sure a CURRENT Mozilla bundle"
echo "  is installed there (stock webOS ships a 1-cert 2011 file). 02-install can"
echo "  drop one in if you place cacert.pem next to it."
