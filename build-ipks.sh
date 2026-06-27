#!/bin/bash
# Build two installable webOS ipks:
#   1. org.webosinternals.browser-tls13  -- modern TLS for the stock browser
#   2. org.webosinternals.ntpdate-sync   -- clock sync (replaces dead palm.com NTP)
set -euo pipefail

BASE="/home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update"
OUT="$BASE/ipks"
VER="1.0.0"
TLSVER="1.0.2"   # browser-tls13: RPATH'd BrowserServer (env-independent, survives reboot)
ARCH="armv7"
STOCK_BS_MD5="0786bdf698220aa82a90838e30355c9f"
MAINT="Herrie <herrie82@gmail.com>"

LIBSSL="$BASE/openssl-1.1.1w/libssl.so.1.1"
LIBCRYPTO="$BASE/openssl-1.1.1w/libcrypto.so.1.1"
LIBCOMPAT="$BASE/libssl_compat.so"
LIBCURL="$BASE/curl-7.88.1/lib/.libs/libcurl.so.4.8.0"
BROWSERSERVER="$BASE/BrowserServer.bin"   # stock 3.0.5 BrowserServer (md5 $STOCK_BS_MD5)
NTPJOB="/tmp/ntpdate-sync"

rm -rf "$OUT"; mkdir -p "$OUT"
TARFLAGS="--owner=0 --group=0 --numeric-owner -p"

pack_ipk() { # $1=builddir  $2=ipkname
  local b="$1" name="$2"
  printf '2.0\n' > "$b/debian-binary"
  ( cd "$b/control" && chmod 0755 p* 2>/dev/null || true; tar $TARFLAGS -czf ../control.tar.gz ./* )
  ( cd "$b/data"    && tar $TARFLAGS -czf ../data.tar.gz ./* )
  ( cd "$b" && ar rc "$OUT/$name" debian-binary control.tar.gz data.tar.gz )
  echo "  built $name"
}

############################################################################
# IPK 1: browser-tls13
############################################################################
B1="$OUT/_build_tls13"
mkdir -p "$B1/control" "$B1/data/usr/lib/ssl11"
L="$B1/data/usr/lib/ssl11"
install -m0755 "$LIBSSL"    "$L/libssl.so.1.1"
install -m0755 "$LIBCRYPTO" "$L/libcrypto.so.1.1"
install -m0755 "$LIBCOMPAT" "$L/libssl_compat.so"
install -m0755 "$LIBCURL"   "$L/libcurl.so.4.8.0"
ln -s libcurl.so.4.8.0 "$L/libcurl.so.4"
ln -s libssl.so.1.1    "$L/libssl.so.0.9.8"
ln -s libcrypto.so.1.1 "$L/libcrypto.so.0.9.8"

# RPATH'd BrowserServer: bakes /usr/lib/ssl11 into DT_RPATH and adds the compat
# shim as NEEDED, so the browser loads the 1.1 stack regardless of which launcher
# starts it (upstart OR ls-hubd demand) and with no env vars. postinst swaps it in.
cp "$BROWSERSERVER" "$L/BrowserServer.rpath"
chmod 0755 "$L/BrowserServer.rpath"
patchelf --force-rpath --set-rpath /usr/lib/ssl11 "$L/BrowserServer.rpath"
patchelf --add-needed libssl_compat.so "$L/BrowserServer.rpath"

ISIZE1=$(du -sk "$B1/data" | cut -f1)000
cat > "$B1/control/control" <<EOF
Package: org.webosinternals.browser-tls13
Version: $TLSVER
Architecture: $ARCH
Maintainer: $MAINT
Section: misc
Priority: optional
Depends:
InstalledSize: $ISIZE1
Description: Modern TLS 1.2/1.3 for the stock webOS TouchPad browser.
 Installs a process-private OpenSSL 1.1.1w + curl (with zlib) under
 /usr/lib/ssl11 and wires it into BrowserServer via LD_LIBRARY_PATH. The two
 custom OpenSSL libs relocate ssl->ctx (0xD8) and X509_STORE_CTX->cert (0x8) to
 the offsets libWebKitLuna hardcodes, so the browser's cert callback works.
 No system binary is modified and the User-Agent is left at the webOS default.
 NOTE: requires a current CA bundle in /etc/ssl/certs/ca-certificates.crt
 (install your Mozilla ca-certificates ipk).
EOF

cat > "$B1/control/preinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
exit 0
EOF

cat > "$B1/control/postinst" <<EOF
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
STOCK_BS_MD5="$STOCK_BS_MD5"
EOF
cat >> "$B1/control/postinst" <<'EOF'

# 1. swap in the RPATH'd BrowserServer (loads /usr/lib/ssl11 with no env, so it
#    works regardless of which launcher starts it -- the env/wrapper approach
#    lost the upstart-vs-ls-hubd race on boot). Back up the stock binary once.
cur=$(md5sum /usr/bin/BrowserServer 2>/dev/null | cut -d' ' -f1)
if [ "$cur" = "$STOCK_BS_MD5" ]; then
    cp -p /usr/bin/BrowserServer /usr/bin/BrowserServer.tls13-orig
    cp -f /usr/lib/ssl11/BrowserServer.rpath /usr/bin/BrowserServer
    chmod 755 /usr/bin/BrowserServer
elif [ -f /usr/bin/BrowserServer.tls13-orig ]; then
    # reinstall/upgrade: original already backed up, (re)apply the rpath binary
    cp -f /usr/lib/ssl11/BrowserServer.rpath /usr/bin/BrowserServer
    chmod 755 /usr/bin/BrowserServer
else
    echo "WARNING: /usr/bin/BrowserServer ($cur) is not the expected stock 3.0.5 binary;"
    echo "         skipping the RPATH swap - modern TLS will NOT load in the browser."
fi

# 2. warn if no modern CA bundle
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 0)
[ "$n" -lt 50 ] && echo "WARNING: /etc/ssl/certs/ca-certificates.crt has only $n certs - install a current Mozilla CA bundle or cert validation will fail."

# 3. restart browser
stop browserserver 2>/dev/null || true
n=0; while [ $n -lt 8 ]; do ps=$(pidof BrowserServer 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; n=$((n+1)); sleep 1; done
start browserserver 2>/dev/null || true
exit 0
EOF

cat > "$B1/control/prerm" <<'EOF'
#!/bin/sh
stop browserserver 2>/dev/null || true
stop browserservermojo 2>/dev/null || true
exit 0
EOF

cat > "$B1/control/postrm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop browserserver 2>/dev/null || true
n=0; while [ $n -lt 8 ]; do ps=$(pidof BrowserServer 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; n=$((n+1)); sleep 1; done
# restore the stock BrowserServer
[ -f /usr/bin/BrowserServer.tls13-orig ] && mv -f /usr/bin/BrowserServer.tls13-orig /usr/bin/BrowserServer
rm -rf /usr/lib/ssl11
start browserserver 2>/dev/null || true
exit 0
EOF
pack_ipk "$B1" "org.webosinternals.browser-tls13_${TLSVER}_${ARCH}.ipk"

############################################################################
# IPK 2: ntpdate-sync
############################################################################
B2="$OUT/_build_ntp"
mkdir -p "$B2/control" "$B2/data/etc/event.d"
install -m0755 "$NTPJOB" "$B2/data/etc/event.d/ntpdate-sync"

ISIZE2=$(du -sk "$B2/data" | cut -f1)000
cat > "$B2/control/control" <<EOF
Package: org.webosinternals.ntpdate-sync
Version: $VER
Architecture: $ARCH
Maintainer: $MAINT
Section: misc
Priority: optional
Depends:
InstalledSize: $ISIZE2
Description: NTP clock sync for webOS TouchPad.
 webOS's built-in time sync targets dead palm.com servers, so the clock
 free-runs and drifts -- which breaks TLS certificate validity windows. This
 installs an upstart job that syncs from public NTP (pool.ntp.org) at boot
 (retrying while Wi-Fi comes up) and every 6 hours, via the device's ntpdate.
EOF

cat > "$B2/control/preinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/postinst" <<'EOF'
#!/bin/sh
start ntpdate-sync 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/prerm" <<'EOF'
#!/bin/sh
stop ntpdate-sync 2>/dev/null || true
exit 0
EOF
pack_ipk "$B2" "org.webosinternals.ntpdate-sync_${VER}_${ARCH}.ipk"

echo "=== output ==="
ls -l "$OUT"/*.ipk
