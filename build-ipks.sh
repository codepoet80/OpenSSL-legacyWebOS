#!/bin/bash
# Build the webOS ipks in the webos-internals App-Manager convention so they
# install via Preware / App Catalog / WebOS Quick Install (which extract under
# /media/cryptofs/apps and run pmPostInstall.script from there) -- as well as via
# plain `ipkg install`.
#
#   org.webosinternals.browser-tls13  -- modern TLS for the stock browser
#   org.webosinternals.ntpdate-sync   -- clock sync (dead palm.com NTP replacement)
#   org.webosinternals.curl-tls13     -- modern command-line curl (/usr/bin/curl11)
#
# Layout (self-contained app -- the correct webOS convention; cf. com.palm.rootcertsupdate):
#   ar order: debian-binary, data.tar.gz, control.tar.gz, pmPostInstall.script, pmPreRemove.script
#   data ships everything under ./usr/palm/applications/<id>/ (appinfo.json + files/<payload>);
#   the postinst / pmPostInstall.script relocates files/ into the live system.
#
# Install fixes layered on the app layout:
#   * robust ONE-TIME BrowserServer backup -- works on any pre-existing binary, and
#     never saves our own RPATH'd build as if it were stock (so it stays uninstallable);
#   * teardown that won't brick the browser when no stock backup exists.
set -euo pipefail

BASE="/home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update"
OUT="$BASE/ipks"; ARCH="armv7"
MAINT="WebOS Internals <support@webos-internals.org>"
TLSVER="1.1.1"   # browser-tls13: app-layout + robust backup / safe teardown
NTPVER="2.0.1"   # ntpdate-sync: app-layout
CURLVER="1.0.0"  # curl-tls13: self-contained modern command-line curl (/usr/bin/curl11)
STOCK_BS_MD5="0786bdf698220aa82a90838e30355c9f"

LIBSSL="$BASE/openssl-1.1.1w/libssl.so.1.1"
LIBCRYPTO="$BASE/openssl-1.1.1w/libcrypto.so.1.1"
LIBCOMPAT="$BASE/libssl_compat.so"
LIBCURL="$BASE/curl-7.88.1/lib/.libs/libcurl.so.4.8.0"
CURLBIN="$BASE/curl-7.88.1/src/.libs/curl"
BROWSERSERVER="$BASE/BrowserServer.bin"
NTPSRC="$BASE/ntpdate-sync"

rm -rf "$OUT"; mkdir -p "$OUT"
T="--owner=0 --group=0 --numeric-owner --format=ustar"
# 1x1 transparent png (icon)
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

pack() { # $1 builddir  $2 ipkname
  local b="$1" name="$2"
  printf '2.0\n' > "$b/debian-binary"
  ( cd "$b/control" && tar $T -czf ../control.tar.gz . )
  ( cd "$b/data"    && tar $T -czf ../data.tar.gz    . )
  # webOS App-Manager hooks: the luna appinstaller (WOSQI / App Catalog / Preware
  # app installs) runs these TOP-LEVEL scripts, not the Debian control postinst.
  # Make them identical to postinst/prerm so every install path applies the bits.
  cp "$b/control/postinst" "$b/pmPostInstall.script"
  cp "$b/control/prerm"    "$b/pmPreRemove.script"
  chmod 0755 "$b/pmPostInstall.script" "$b/pmPreRemove.script"
  # webos-internals ar member order: debian-binary, data.tar.gz, control.tar.gz, pm scripts
  ( cd "$b" && ar rc "$OUT/$name" debian-binary data.tar.gz control.tar.gz \
        pmPostInstall.script pmPreRemove.script )
  echo "  built $name"
}

############################# browser-tls13 #############################
ID=org.webosinternals.browser-tls13
B="$OUT/_b_tls"; APPDIR="$B/data/usr/palm/applications/$ID"; F="$APPDIR/files"
mkdir -p "$B/control" "$F/ssl11"
install -m0644 "$LIBSSL"    "$F/ssl11/libssl.so.1.1"
install -m0644 "$LIBCRYPTO" "$F/ssl11/libcrypto.so.1.1"
install -m0644 "$LIBCOMPAT" "$F/ssl11/libssl_compat.so"
install -m0644 "$LIBCURL"   "$F/ssl11/libcurl.so.4.8.0"
# ship the RPATH'd BrowserServer (DT_RPATH=/usr/lib/ssl11 + libssl_compat as NEEDED)
cp "$BROWSERSERVER" "$F/BrowserServer.rpath"; chmod 0644 "$F/BrowserServer.rpath"
patchelf --force-rpath --set-rpath /usr/lib/ssl11 "$F/BrowserServer.rpath"
patchelf --add-needed libssl_compat.so "$F/BrowserServer.rpath"
RPATH_BS_MD5=$(md5sum "$F/BrowserServer.rpath" | cut -d' ' -f1)   # so postinst never backs up our own binary as "stock"
# app metadata (headless / hidden)
cat > "$APPDIR/appinfo.json" <<EOF
{ "title":"Browser TLS 1.3", "id":"$ID", "version":"$TLSVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>Browser TLS 1.3</title></head><body></body></html>' > "$APPDIR/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR/icon.png"

cat > "$B/control/control" <<EOF
Package: $ID
Version: $TLSVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern TLS 1.2/1.3 for the stock webOS TouchPad browser
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Browser TLS 1.3", "FullDescription":"Adds a process-private OpenSSL 1.1.1w + curl(zlib) under /usr/lib/ssl11 and points the stock BrowserServer at it via RPATH, so the 2011 browser can reach modern TLS 1.2/1.3 sites. Requires a current /etc/ssl/certs/ca-certificates.crt (Mozilla ca-certificates).", "License":"OpenSSL/curl" }
EOF

cat > "$B/control/postinst" <<EOF
#!/bin/sh
STOCK_BS_MD5="$STOCK_BS_MD5"
RPATH_BS_MD5="$RPATH_BS_MD5"
PID="$ID"
EOF
cat >> "$B/control/postinst" <<'EOF'
# App-Manager installs offline under /media/cryptofs/apps and leaves the root ro;
# raw `ipkg install` puts files at / . Find wherever our payload actually landed.
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -d "$d/ssl11" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: browser-tls13 payload not found - install failed"; exit 1; }

# 0. clean stray upstart job-backups from old (<=1.0.3) installs (duplicate launchers)
rm -f /etc/event.d/*.tls13-orig /etc/event.d/*.orig /etc/event.d/*.preua /etc/event.d/*.pre-rpath 2>/dev/null

# 1. install the ssl11 stack to /usr/lib/ssl11 (symlinks made here -- the offline-root
#    filesystem rejects symlink creation during ipkg unpack)
rm -rf /usr/lib/ssl11; mkdir -p /usr/lib/ssl11
cp -f "$SRC/ssl11/libssl.so.1.1" "$SRC/ssl11/libcrypto.so.1.1" \
      "$SRC/ssl11/libssl_compat.so" "$SRC/ssl11/libcurl.so.4.8.0" /usr/lib/ssl11/
chmod 755 /usr/lib/ssl11/*.so*
ln -sf libcurl.so.4.8.0 /usr/lib/ssl11/libcurl.so.4
ln -sf libssl.so.1.1    /usr/lib/ssl11/libssl.so.0.9.8
ln -sf libcrypto.so.1.1 /usr/lib/ssl11/libcrypto.so.0.9.8

# 2. swap in the RPATH'd BrowserServer. Back up whatever browser is currently
#    installed ONCE -- only when no backup exists yet AND it isn't already our
#    RPATH'd build -- so the package stays cleanly uninstallable even on a
#    non-stock BrowserServer, and we never save our own binary as if it were stock.
cur=$(md5sum /usr/bin/BrowserServer 2>/dev/null | cut -d' ' -f1)
if [ ! -f /usr/bin/BrowserServer.tls13-orig ] && [ "$cur" != "$RPATH_BS_MD5" ] && [ -f /usr/bin/BrowserServer ]; then
    cp -p /usr/bin/BrowserServer /usr/bin/BrowserServer.tls13-orig
    [ "$cur" = "$STOCK_BS_MD5" ] || echo "NOTE: backed up a non-stock BrowserServer ($cur) as the uninstall restore point."
fi
cp -f "$SRC/BrowserServer.rpath" /usr/bin/BrowserServer
chmod 755 /usr/bin/BrowserServer

# 3. CA bundle check (no '|| echo 0' -- that yields two values and breaks the test)
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null); [ -z "$n" ] && n=0
[ "$n" -lt 50 ] && echo "WARNING: stale CA bundle ($n certs) -- install a current Mozilla ca-certificates ipk."

# 4. restart browser
stop browserserver 2>/dev/null || true
i=0; while [ $i -lt 8 ]; do ps=$(pidof BrowserServer 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; i=$((i+1)); sleep 1; done
start browserserver 2>/dev/null || true
exit 0
EOF

cat > "$B/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop browserserver 2>/dev/null || true
i=0; while [ $i -lt 8 ]; do ps=$(pidof BrowserServer 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; i=$((i+1)); sleep 1; done
# Restore stock ONLY if we have the backup; otherwise the live BrowserServer is our
# RPATH'd one and removing /usr/lib/ssl11 would leave it unable to load its libs
# (dead browser) -- so keep the stack in place.
if [ -f /usr/bin/BrowserServer.tls13-orig ]; then
    mv -f /usr/bin/BrowserServer.tls13-orig /usr/bin/BrowserServer
    rm -rf /usr/lib/ssl11
else
    echo "WARNING: no BrowserServer.tls13-orig backup; keeping /usr/lib/ssl11 so the browser keeps working."
fi
start browserserver 2>/dev/null || true
exit 0
EOF
chmod 0755 "$B/control/postinst" "$B/control/prerm"
pack "$B" "${ID}_${TLSVER}_${ARCH}.ipk"

############################# ntpdate-sync #############################
ID2=org.webosinternals.ntpdate-sync
B2="$OUT/_b_ntp"; APPDIR2="$B2/data/usr/palm/applications/$ID2"; F2="$APPDIR2/files"
mkdir -p "$B2/control" "$F2"
install -m0644 "$NTPSRC" "$F2/ntpdate-sync"
cat > "$APPDIR2/appinfo.json" <<EOF
{ "title":"NTP Clock Sync", "id":"$ID2", "version":"$NTPVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>NTP Clock Sync</title></head><body></body></html>' > "$APPDIR2/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR2/icon.png"

cat > "$B2/control/control" <<EOF
Package: $ID2
Version: $NTPVER
Architecture: $ARCH
Maintainer: $MAINT
Description: NTP clock sync for webOS TouchPad
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"NTP Clock Sync", "FullDescription":"webOS time sync targets dead palm.com servers; this installs an upstart job that syncs from public NTP (retry-until-success + IP fallbacks) at boot and every 6h, fixing TLS cert validity windows.", "License":"MIT" }
EOF

cat > "$B2/control/postinst" <<EOF
#!/bin/sh
PID="$ID2"
EOF
cat >> "$B2/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    [ -f "$R/usr/palm/applications/$PID/files/ntpdate-sync" ] && { SRC="$R/usr/palm/applications/$PID/files"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: ntpdate-sync payload not found"; exit 1; }
cp -f "$SRC/ntpdate-sync" /etc/event.d/ntpdate-sync
chmod 755 /etc/event.d/ntpdate-sync
stop ntpdate-sync 2>/dev/null || true
start ntpdate-sync 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop ntpdate-sync 2>/dev/null || true
rm -f /etc/event.d/ntpdate-sync
exit 0
EOF
chmod 0755 "$B2/control/postinst" "$B2/control/prerm"
pack "$B2" "${ID2}_${NTPVER}_${ARCH}.ipk"

############################# curl-tls13 #############################
ID3=org.webosinternals.curl-tls13
B3="$OUT/_b_curl"; APPDIR3="$B3/data/usr/palm/applications/$ID3"; F3="$APPDIR3/files"
mkdir -p "$B3/control" "$F3/curl11"
install -m0644 "$LIBSSL"    "$F3/curl11/libssl.so.1.1"
install -m0644 "$LIBCRYPTO" "$F3/curl11/libcrypto.so.1.1"
install -m0644 "$LIBCURL"   "$F3/curl11/libcurl.so.4.8.0"
install -m0644 "$CURLBIN"   "$F3/curl11/curl"
cat > "$APPDIR3/appinfo.json" <<EOF
{ "title":"curl (TLS 1.3)", "id":"$ID3", "version":"$CURLVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>curl TLS 1.3</title></head><body></body></html>' > "$APPDIR3/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR3/icon.png"

cat > "$B3/control/control" <<EOF
Package: $ID3
Version: $CURLVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern command-line curl (7.88.1, TLS 1.2/1.3) for the webOS TouchPad
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"curl TLS 1.3", "FullDescription":"Self-contained curl 7.88.1 (OpenSSL 1.1.1w + zlib) under /usr/lib/curl11, exposed as the command /usr/bin/curl11 (a small LD_LIBRARY_PATH wrapper). The stock /usr/bin/curl is left untouched.", "License":"OpenSSL/curl" }
EOF

cat > "$B3/control/postinst" <<EOF
#!/bin/sh
PID="$ID3"
EOF
cat >> "$B3/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -d "$d/curl11" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: curl-tls13 payload not found"; exit 1; }
rm -rf /usr/lib/curl11; mkdir -p /usr/lib/curl11
cp -f "$SRC/curl11/curl" "$SRC/curl11/libcurl.so.4.8.0" \
      "$SRC/curl11/libssl.so.1.1" "$SRC/curl11/libcrypto.so.1.1" /usr/lib/curl11/
chmod 755 /usr/lib/curl11/*
ln -sf libcurl.so.4.8.0 /usr/lib/curl11/libcurl.so.4
cat > /usr/bin/curl11 <<'WRAP'
#!/bin/sh
exec env LD_LIBRARY_PATH=/usr/lib/curl11 /usr/lib/curl11/curl "$@"
WRAP
chmod 755 /usr/bin/curl11
exit 0
EOF

cat > "$B3/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
rm -f /usr/bin/curl11
rm -rf /usr/lib/curl11
exit 0
EOF
chmod 0755 "$B3/control/postinst" "$B3/control/prerm"
pack "$B3" "${ID3}_${CURLVER}_${ARCH}.ipk"

echo "=== output ==="; ls -l "$OUT"/*.ipk
