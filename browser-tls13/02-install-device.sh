#!/bin/sh
#
# 02-install-device.sh  --  Install the process-private OpenSSL 1.1 browser
#                           stack on the TouchPad.  Runs ON THE DEVICE (as root).
#
# symlink-redirect approach: NO binary is modified.  We only:
#   1. unpack  /usr/lib/ssl11/                       (1.1 libs + 0.9.8-named symlinks)
#   2. edit    /etc/event.d/browserserver[mojo]      (.orig backup) -> LD_LIBRARY_PATH+shim
#   3. install /etc/ssl/certs/ca-certificates.crt    (modern Mozilla bundle, if cacert.pem present)
#
# System libssl/libcrypto/libcurl and all binaries stay byte-identical, so every
# other service keeps running on 0.9.8 and boot is unaffected.  Fully reversible
# by 03-rollback-device.sh.
#
set -e
PAYLOAD="${1:-/tmp/ssl11-payload.tar.gz}"
CACERT="${2:-/tmp/cacert.pem}"
SSL11=/usr/lib/ssl11

[ -f "$PAYLOAD" ] || { echo "ERROR: payload not found: $PAYLOAD"; exit 1; }

echo "== 1. unpack private lib dir (symlink-preserving) =="
rm -rf "$SSL11"
tar xzf "$PAYLOAD" -C /
ls -la "$SSL11"

echo "== 2. wire LD_LIBRARY_PATH + compat shim into the browser upstart job(s) =="
patch_job() {
    job="$1"
    [ -f "$job" ] || { echo "  skip (absent): $job"; return; }
    if grep -q "ssl11 browser TLS1.3" "$job"; then echo "  already patched: $job"; return; fi
    [ -f "$job.orig" ] || cp -p "$job" "$job.orig"
    # busybox-safe: awk reads the pristine .orig, augments the ptmalloc LD_PRELOAD
    # line with our shim and adds LD_LIBRARY_PATH=ssl11. Idempotent.
    awk '
        /LD_PRELOAD=.*libptmalloc3/ && !injected {
            print "    export LD_PRELOAD=\"/usr/lib/libptmalloc3.so /usr/lib/ssl11/libssl_compat.so\""
            print "    # ssl11 browser TLS1.3 (added by installer)"
            print "    export LD_LIBRARY_PATH=\"/usr/lib/ssl11:${LD_LIBRARY_PATH}\""
            injected = 1; next
        }
        { print }
    ' "$job.orig" > "$job.tmp" && mv "$job.tmp" "$job"
    echo "  patched: $job"
}
patch_job /etc/event.d/browserserver
patch_job /etc/event.d/browserservermojo

echo "== 3. install modern CA bundle (browser CURLOPT_CAINFO target) =="
B=/etc/ssl/certs/ca-certificates.crt
if [ -f "$CACERT" ]; then
    [ -f "$B.stock2011" ] || cp -p "$B" "$B.stock2011"
    cp -f "$CACERT" "$B"
    echo "  installed $(grep -c 'BEGIN CERTIFICATE' "$B") certs (backup: $B.stock2011)"
else
    n=$(grep -c 'BEGIN CERTIFICATE' "$B" 2>/dev/null || echo 0)
    echo "  no $CACERT provided; current bundle has $n certs."
    [ "$n" -lt 50 ] && echo "  WARNING: bundle looks like the stock 2011 file -- modern sites will fail cert verify until you install a current Mozilla bundle here."
fi

echo "== restart browser =="
stop browserserver 2>/dev/null || true
start browserserver 2>/dev/null || true
sleep 5

PID=$(pidof BrowserServer || true)
echo "== verify (PID=$PID) =="
if [ -n "$PID" ]; then
    echo "  ssl/crypto/curl libs mapped:"
    grep -oE '/usr/lib[^ ]*(ssl|crypto|curl)[^ ]*' /proc/$PID/maps | sort -u | sed 's/^/    /'
    if grep -E '/usr/lib/lib(ssl|crypto)\.so\.0\.9\.8' /proc/$PID/maps | grep -qv ssl11; then
        echo "  WARNING: a real 0.9.8 lib is mapped in the browser process!"
    else
        echo "  OK: browser process is on OpenSSL 1.1, no real 0.9.8 mapped."
    fi
else
    echo "  ERROR: BrowserServer not running. Check: status browserserver"
fi
echo
echo "Now open the browser on the device and load https://www.cloudflare.com/ or https://github.com/"
