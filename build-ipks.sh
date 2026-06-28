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

# Resolve BASE to this script's own directory (the repo checkout), so the build
# works wherever it's cloned -- inputs (openssl-1.1.1w/, curl-7.88.1/, libssl_compat.so,
# ntpdate-sync, BrowserServer.bin) and the ipks/ output are relative to it.
BASE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OUT="$BASE/ipks"; ARCH="armv7"
MAINT="WebOS Internals <support@webos-internals.org>"
TLSVER="1.1.1"   # browser-tls13: app-layout + robust backup / safe teardown
NTPVER="2.0.1"   # ntpdate-sync: app-layout
CURLVER="1.0.1"  # curl-tls13: modern curl as /usr/bin/curl11 AND /usr/bin/curl (stock backed up); CA bundle defaulted
LUNAVER="1.0.0"  # luna-tls13: app WebKit (LunaSysMgr/WebAppMgr) -> ssl11; needs browser-tls13
MAILVER="1.1.0"  # mail-tls13: mojomail (EAS/IMAP/POP/SMTP) -> purpose-built libcurl (vs OpenSSL 1.1) + ssl11; needs browser-tls13 + curl-mail/ (see BUILDING-mail.md)
STOCK_BS_MD5="0786bdf698220aa82a90838e30355c9f"

LIBSSL="$BASE/openssl-1.1.1w/libssl.so.1.1"
LIBCRYPTO="$BASE/openssl-1.1.1w/libcrypto.so.1.1"
LIBCOMPAT="$BASE/libssl_compat.so"
LIBCURL="$BASE/curl-7.88.1/lib/.libs/libcurl.so.4.8.0"
CURLBIN="$BASE/curl-7.88.1/src/.libs/curl"
BROWSERSERVER="$BASE/BrowserServer.bin"
NTPSRC="$BASE/ntpdate-sync"

# --- build prerequisites (fail fast, before doing any work) -------------------
command -v patchelf >/dev/null 2>&1 || {
  echo "ERROR: 'patchelf' not found in PATH -- required to RPATH BrowserServer." >&2
  echo "       Install it (e.g. 'apt-get install patchelf', or 'brew install patchelf')." >&2
  exit 1
}

# GNU ar is REQUIRED. The pmPostInstall.script/pmPreRemove.script members have long
# names; BSD ar (macOS /usr/bin/ar) encodes those in a format the device's ipkg/
# appinstaller can't read, so the packages would install but never activate.
AR=""
for c in gar ar /usr/local/opt/binutils/bin/ar /opt/homebrew/opt/binutils/bin/ar; do
  { command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; } || continue
  "$c" --version 2>/dev/null | grep -qi 'GNU ar' && { AR="$c"; break; }
done
[ -n "$AR" ] || {
  echo "ERROR: GNU ar not found (your 'ar' is BSD, e.g. stock macOS)." >&2
  echo "       BSD ar can't write the GNU long-name members the device needs." >&2
  echo "       Install GNU binutils: 'brew install binutils' (provides GNU ar), or build on Linux." >&2
  exit 1
}

# We need the STOCK 3.0.5 BrowserServer to RPATH. If it isn't already in the repo,
# fetch it from a connected (factory/stock) TouchPad over novacom.
if [ ! -f "$BROWSERSERVER" ]; then
  echo "BrowserServer.bin not present -- fetching the stock binary from a connected TouchPad..."
  command -v novacom >/dev/null 2>&1 || {
    echo "ERROR: 'novacom' not found in PATH (HP webOS / Palm SDK novacom)." >&2
    echo "       Install novacom, OR place a stock 3.0.5 BrowserServer" >&2
    echo "       (md5 $STOCK_BS_MD5) at: $BROWSERSERVER" >&2
    exit 1
  }
  if ! novacom -l 2>/dev/null | grep -qiE 'usb|tcp|topaz'; then
    echo "ERROR: no webOS device detected over novacom -- cannot fetch BrowserServer." >&2
    echo "       Connect a TouchPad in novacom mode (USB) and retry. 'novacom -l' should" >&2
    echo "       list a device, e.g.:  63055 <id> usb topaz-linux" >&2
    echo "       (Or place a stock BrowserServer at $BROWSERSERVER to skip the fetch.)" >&2
    exit 1
  fi
  novacom get file:///usr/bin/BrowserServer > "$BROWSERSERVER" 2>/dev/null
  if [ ! -s "$BROWSERSERVER" ]; then
    echo "ERROR: novacom fetch of /usr/bin/BrowserServer failed (empty result)." >&2
    rm -f "$BROWSERSERVER"
    exit 1
  fi
  got=$(md5sum "$BROWSERSERVER" | cut -d' ' -f1)
  if [ "$got" != "$STOCK_BS_MD5" ]; then
    echo "ERROR: fetched BrowserServer md5 ($got) is NOT the stock 3.0.5 binary" >&2
    echo "       (expected $STOCK_BS_MD5). The device isn't a clean 3.0.5, or its browser" >&2
    echo "       is already patched. Factory-reset the TouchPad and retry, or place a" >&2
    echo "       known-stock BrowserServer at $BROWSERSERVER to override." >&2
    rm -f "$BROWSERSERVER"
    exit 1
  fi
  echo "  fetched stock BrowserServer ($got) -> $BROWSERSERVER"
else
  echo "Using existing BrowserServer.bin ($(md5sum "$BROWSERSERVER" | cut -d' ' -f1))"
fi
# -----------------------------------------------------------------------------

# Clean only our build artifacts in $OUT (the repo ipks/ dir) -- keep README.md etc.
mkdir -p "$OUT"
rm -f "$OUT"/*.ipk
rm -rf "$OUT"/_b_tls "$OUT"/_b_ntp "$OUT"/_b_curl "$OUT"/_b_luna
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
  ( cd "$b" && "$AR" rc "$OUT/$name" debian-binary data.tar.gz control.tar.gz \
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
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"curl TLS 1.3", "FullDescription":"curl 7.88.1 (OpenSSL 1.1.1w + zlib) under /usr/lib/curl11, installed as /usr/bin/curl11 AND /usr/bin/curl (stock 0.9.8 backed up to /usr/bin/curl.0.9.8-orig, restored on uninstall). Wrapper defaults the CA bundle to /etc/ssl/certs/ca-certificates.crt.", "License":"OpenSSL/curl" }
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
# Wrapper defaults the CA bundle to webOS's (the build's compiled-in CA path doesn't
# exist on-device); respects an existing CURL_CA_BUNDLE, and explicit --cacert wins.
cat > /usr/bin/curl11 <<'WRAP'
#!/bin/sh
[ -n "$CURL_CA_BUNDLE" ] || CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE LD_LIBRARY_PATH=/usr/lib/curl11
exec /usr/lib/curl11/curl "$@"
WRAP
chmod 755 /usr/bin/curl11
# Also take over /usr/bin/curl (back up the stock 0.9.8 binary once).
if [ -f /usr/bin/curl ] && [ ! -f /usr/bin/curl.0.9.8-orig ]; then
    cp -p /usr/bin/curl /usr/bin/curl.0.9.8-orig
fi
cp -f /usr/bin/curl11 /usr/bin/curl
chmod 755 /usr/bin/curl
exit 0
EOF

cat > "$B3/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
# Restore stock curl if backed up; else drop our wrapper so /usr/bin/curl isn't left dangling.
if [ -f /usr/bin/curl.0.9.8-orig ]; then
    mv -f /usr/bin/curl.0.9.8-orig /usr/bin/curl
else
    grep -q 'LD_LIBRARY_PATH=/usr/lib/curl11' /usr/bin/curl 2>/dev/null && rm -f /usr/bin/curl
fi
rm -f /usr/bin/curl11
rm -rf /usr/lib/curl11
exit 0
EOF
chmod 0755 "$B3/control/postinst" "$B3/control/prerm"
pack "$B3" "${ID3}_${CURLVER}_${ARCH}.ipk"

############################# luna-tls13 #############################
# Routes the app WebKit host (LunaSysMgr / WebAppMgr -- where Mojo/Enyo XHR runs) at
# /usr/lib/ssl11. No payload: the postinst edits the LunaSysMgr upstart launcher.
# REQUIRES browser-tls13 (for /usr/lib/ssl11); REBOOT after install.
ID4=org.webosinternals.luna-tls13
B4="$OUT/_b_luna"; APPDIR4="$B4/data/usr/palm/applications/$ID4"
mkdir -p "$B4/control" "$APPDIR4"
cat > "$APPDIR4/appinfo.json" <<EOF
{ "title":"Luna TLS 1.3", "id":"$ID4", "version":"$LUNAVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>Luna TLS 1.3</title></head><body></body></html>' > "$APPDIR4/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR4/icon.png"

cat > "$B4/control/control" <<EOF
Package: $ID4
Version: $LUNAVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern TLS 1.2/1.3 for webOS apps (Mojo/Enyo WebKit)
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Luna TLS 1.3", "FullDescription":"Routes the app WebKit host (LunaSysMgr/WebAppMgr) through the OpenSSL 1.1.1w stack under /usr/lib/ssl11 so in-app HTTPS (Mojo/Enyo XHR, enyo.WebService) negotiates TLS 1.2/1.3. REQUIRES org.webosinternals.browser-tls13 (provides /usr/lib/ssl11). Edits the LunaSysMgr upstart launcher; REBOOT after install. Recovery: novacomd survives a UI failure -- restore /var/luna/LunaSysMgr.tls13-orig to /etc/event.d/LunaSysMgr and reboot.", "License":"OpenSSL/curl" }
EOF

# postinst: patch the LunaSysMgr launcher to load ssl11 (+ compat shim). Backup goes
# OUTSIDE /etc/event.d (upstart runs every file there as a job). Requires the ssl11
# stack; never restarts LunaSysMgr (that would kill the UI/Preware) -- reboot applies it.
cat > "$B4/control/postinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
L=/etc/event.d/LunaSysMgr
COMPAT=/usr/lib/ssl11/libssl_compat.so
if [ ! -f "$COMPAT" ]; then
    echo "luna-tls13 ERROR: /usr/lib/ssl11 stack not found -- install org.webosinternals.browser-tls13 first. Not patching."
    exit 1
fi
if grep -q 'ssl11/libssl_compat.so' "$L" 2>/dev/null; then
    echo "luna-tls13: LunaSysMgr launcher already patched."
    exit 0
fi
mkdir -p /var/luna 2>/dev/null
[ -f /var/luna/LunaSysMgr.tls13-orig ] || cp -p "$L" /var/luna/LunaSysMgr.tls13-orig
awk '
/export LD_PRELOAD="/ {
    sub(/"[ \t]*$/, " /usr/lib/ssl11/libssl_compat.so\"")
    print
    print "\texport LD_LIBRARY_PATH=/usr/lib/ssl11"
    next
}
{ print }
' "$L" > /tmp/lsm.tls13.$$ && cat /tmp/lsm.tls13.$$ > "$L"
rm -f /tmp/lsm.tls13.$$
if grep -q 'ssl11/libssl_compat.so' "$L" && grep -q 'LD_LIBRARY_PATH=/usr/lib/ssl11' "$L"; then
    echo "luna-tls13: patched LunaSysMgr launcher. REBOOT to route app WebKit through OpenSSL 1.1 / TLS 1.3."
else
    echo "luna-tls13 WARNING: LD_PRELOAD anchor not found; restoring stock launcher (no change)."
    cp -f /var/luna/LunaSysMgr.tls13-orig "$L"
    exit 1
fi
exit 0
EOF

cat > "$B4/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
L=/etc/event.d/LunaSysMgr
if [ -f /var/luna/LunaSysMgr.tls13-orig ]; then
    cp -f /var/luna/LunaSysMgr.tls13-orig "$L"
    rm -f /var/luna/LunaSysMgr.tls13-orig
    echo "luna-tls13: restored stock LunaSysMgr launcher. REBOOT to return app TLS to stock."
else
    awk '
    /export LD_PRELOAD="/ { gsub(/ \/usr\/lib\/ssl11\/libssl_compat.so/, ""); print; next }
    /export LD_LIBRARY_PATH=\/usr\/lib\/ssl11/ { next }
    { print }
    ' "$L" > /tmp/lsm.unp.$$ && cat /tmp/lsm.unp.$$ > "$L"
    rm -f /tmp/lsm.unp.$$
    echo "luna-tls13: removed patch lines (no backup found). REBOOT to revert."
fi
exit 0
EOF
chmod 0755 "$B4/control/postinst" "$B4/control/prerm"
pack "$B4" "${ID4}_${LUNAVER}_${ARCH}.ipk"

############################# mail-tls13 #############################
# Routes the native mail transports (mojomail-eas/imap/pop/smtp -- where the Email
# app's EAS/IMAP/POP/SMTP sync actually runs) through the OpenSSL 1.1.1w stack, so
# the 2011 mail client can reach modern TLS 1.2/1.3 servers (Zoho, Gmail, etc.).
#
# KEY DESIGN (the long story is in BUILDING-mail.md): mojomail does HTTPS via libcurl
# (EAS) / libpalmsocket (line protocols). Two proven dead ends: (a) ssl11's libcurl
# 7.88.1 SIGSEGVs in curl_multi_remove_handle (mojomail's glibcurl glue was built for
# curl 7.21.7+c-ares, incompatible with the 11-years-newer multi/resolver internals);
# (b) keeping STOCK libcurl 7.21.7 on ssl11 OpenSSL does the TLS1.3 handshake fine but
# SIGSEGVs inspecting the X509 cert (ssl11 OpenSSL only carries libWebKitLuna's offset
# relocation, not libcurl's). FIX: ship a purpose-built libcurl (~7.51-7.61, --enable-
# ares, compiled against OpenSSL 1.1 *headers* so no offset assumptions) into a redirect
# dir /usr/lib/ssl11mail, and point the four launchers there. REQUIRES browser-tls13
# (for /usr/lib/ssl11). No reboot. The libcurl must be cross-built first -- see
# BUILDING-mail.md; if curl-mail/ is absent this package is SKIPPED (not shipped broken).
MAILCURL=""
for f in "$BASE"/curl-mail/lib/.libs/libcurl.so.4.* "$BASE"/curl-mail/libcurl.so.4.*; do
  [ -f "$f" ] && { MAILCURL="$f"; break; }
done
if [ -z "$MAILCURL" ]; then
  echo "  SKIP mail-tls13: no cross-built libcurl at curl-mail/lib/.libs/libcurl.so.4.* (see BUILDING-mail.md)"
else
  MAILCURL_BN="$(basename "$MAILCURL")"
  ID5=org.webosinternals.mail-tls13
  B5="$OUT/_b_mail"; APPDIR5="$B5/data/usr/palm/applications/$ID5"; F5="$APPDIR5/files"
  rm -rf "$B5"; mkdir -p "$B5/control" "$F5/ssl11mail"
  install -m0644 "$MAILCURL" "$F5/ssl11mail/$MAILCURL_BN"
  cat > "$APPDIR5/appinfo.json" <<EOF
{ "title":"Mail TLS 1.3", "id":"$ID5", "version":"$MAILVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
  echo '<html><head><title>Mail TLS 1.3</title></head><body></body></html>' > "$APPDIR5/index.html"
  echo "$PNG_B64" | base64 -d > "$APPDIR5/icon.png"

  cat > "$B5/control/control" <<EOF
Package: $ID5
Version: $MAILVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern TLS 1.2/1.3 for the webOS mail client (EAS/IMAP/POP/SMTP)
Section: System
Priority: optional
Depends: org.webosinternals.browser-tls13
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Mail TLS 1.3", "FullDescription":"Routes the native mail transports (mojomail-eas/imap/pop/smtp) through a purpose-built libcurl (compiled against OpenSSL 1.1.1w) under /usr/lib/ssl11mail, so the stock Email app can sync Exchange ActiveSync/IMAP/POP/SMTP accounts on modern TLS 1.2/1.3 servers (Zoho, Gmail, etc.). Patches the four D-Bus service launchers (backups in /var/luna). REQUIRES org.webosinternals.browser-tls13 (provides /usr/lib/ssl11) and a current /etc/ssl/certs/ca-certificates.crt. No reboot needed.", "License":"OpenSSL/curl" }
EOF

  # postinst: build the OpenSSL-1.1 redirect dir with OUR libcurl + patch the four
  # launchers. Refuses if the ssl11 stack is absent (so it can't half-apply). Backups
  # go OUTSIDE /etc/event.d. Never touches /usr/lib/ssl11 (browser/curl11 unaffected).
  cat > "$B5/control/postinst" <<EOF
#!/bin/sh
MAILCURL_BN="$MAILCURL_BN"
PID="$ID5"
EOF
  cat >> "$B5/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SSL11=/usr/lib/ssl11
MAILDIR=/usr/lib/ssl11mail
if [ ! -f "$SSL11/libssl_compat.so" ] || [ ! -f "$SSL11/libssl.so.1.1" ]; then
    echo "mail-tls13 ERROR: /usr/lib/ssl11 stack not found -- install org.webosinternals.browser-tls13 first. Not patching."
    exit 1
fi
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -f "$d/ssl11mail/$MAILCURL_BN" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "mail-tls13 ERROR: payload (libcurl) not found -- install failed"; exit 1; }

# 1. redirect dir: OUR libcurl (built vs OpenSSL 1.1 headers) + ssl11 OpenSSL. The 1.1
#    sonames satisfy our libcurl's NEEDED; the 0.9.8 aliases satisfy the OTHER mojomail
#    consumers (libpalmsocket etc.) that still reference the 0.9.8 sonames. libcares.so.2
#    resolves from /usr/lib (the device's). No 7.88 libcurl here.
rm -rf "$MAILDIR"; mkdir -p "$MAILDIR"
cp -f "$SRC/ssl11mail/$MAILCURL_BN" "$MAILDIR/$MAILCURL_BN"; chmod 755 "$MAILDIR/$MAILCURL_BN"
ln -sf "$MAILCURL_BN"            "$MAILDIR/libcurl.so.4"
ln -sf "$SSL11/libssl.so.1.1"    "$MAILDIR/libssl.so.1.1"
ln -sf "$SSL11/libcrypto.so.1.1" "$MAILDIR/libcrypto.so.1.1"
ln -sf "$SSL11/libssl.so.1.1"    "$MAILDIR/libssl.so.0.9.8"
ln -sf "$SSL11/libcrypto.so.1.1" "$MAILDIR/libcrypto.so.0.9.8"
ln -sf "$SSL11/libssl_compat.so" "$MAILDIR/libssl_compat.so"

# 2. patch the four mojomail D-Bus launchers (idempotent; backup each once to /var/luna)
mkdir -p /var/luna 2>/dev/null
PFX='/usr/bin/env LD_LIBRARY_PATH=/usr/lib/ssl11mail LD_PRELOAD=/usr/lib/ssl11mail/libssl_compat.so CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'
patched=0
for s in eas imap pop smtp; do
    F="/usr/share/dbus-1/system-services/com.palm.$s.service"
    [ -f "$F" ] || continue
    grep -q 'ssl11mail' "$F" 2>/dev/null && { patched=$((patched+1)); continue; }
    cp -p "$F" "/var/luna/com.palm.$s.service.tls13-orig"
    awk -v p="$PFX" '
      /^Exec=\/usr\/bin\/mojomail-/ && $0 !~ /ssl11mail/ { sub(/^Exec=/, "Exec=" p " "); print; next }
      { print }
    ' "$F" > "/tmp/mail.$s.$$" && cat "/tmp/mail.$s.$$" > "$F"
    rm -f "/tmp/mail.$s.$$"
    if grep -q 'ssl11mail' "$F" 2>/dev/null; then
        patched=$((patched+1))
    else
        cp -f "/var/luna/com.palm.$s.service.tls13-orig" "$F"   # restore on failure
        echo "mail-tls13 WARNING: could not patch $F (left stock)."
    fi
done
echo "mail-tls13: patched $patched / 4 mojomail launcher(s)."

# 3. CA bundle sanity (mail does REAL cert validation -- unlike a plain version bump)
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null); [ -z "$n" ] && n=0
[ "$n" -lt 50 ] && echo "mail-tls13 WARNING: stale CA bundle ($n certs) -- mail cert checks may fail; install a current ca-certificates."

# 4. reload the service registry + stop running transports so they respawn patched
/usr/bin/ls-control scan-services 2>/dev/null || true
for b in mojomail-eas mojomail-imap mojomail-pop mojomail-smtp; do killall "$b" 2>/dev/null; done
echo "mail-tls13: done. Open Email and refresh an account (or wait for scheduled sync) to test."
exit 0
EOF

  cat > "$B5/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
for s in eas imap pop smtp; do
    F="/usr/share/dbus-1/system-services/com.palm.$s.service"
    B="/var/luna/com.palm.$s.service.tls13-orig"
    [ -f "$F" ] || continue
    if [ -f "$B" ]; then
        cp -f "$B" "$F"; rm -f "$B"
    else
        # no backup -- strip our 5-token env prefix in place (env + 4 VAR= tokens)
        awk '/^Exec=\/usr\/bin\/env .*mojomail-/ { sub(/^Exec=\/usr\/bin\/env [^ ]* [^ ]* [^ ]* [^ ]* /, "Exec="); print; next } { print }' "$F" > "/tmp/mailu.$s.$$" && cat "/tmp/mailu.$s.$$" > "$F"
        rm -f "/tmp/mailu.$s.$$"
    fi
done
rm -rf /usr/lib/ssl11mail
/usr/bin/ls-control scan-services 2>/dev/null || true
for b in mojomail-eas mojomail-imap mojomail-pop mojomail-smtp; do killall "$b" 2>/dev/null; done
echo "mail-tls13: reverted mojomail launchers to stock."
exit 0
EOF
  chmod 0755 "$B5/control/postinst" "$B5/control/prerm"
  pack "$B5" "${ID5}_${MAILVER}_${ARCH}.ipk"
fi

echo "=== output ==="; ls -l "$OUT"/*.ipk
