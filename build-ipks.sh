#!/bin/bash
# Build two installable webOS ipks:
#   1. org.webosinternals.browser-tls13  -- modern TLS for the stock browser
#   2. org.webosinternals.ntpdate-sync   -- clock sync (replaces dead palm.com NTP)
set -euo pipefail

BASE="/home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update"
OUT="$BASE/ipks"
VER="1.0.0"
TLSVER="1.0.6"   # browser-tls13: RPATH'd BrowserServer, offline-root-aware postinst + pmPostInstall.script (works via App-Manager too), robust stock backup
ARCH="armv7"
STOCK_BS_MD5="0786bdf698220aa82a90838e30355c9f"
MAINT="Herrie <herrie82@gmail.com>"

LIBSSL="$BASE/openssl-1.1.1w/libssl.so.1.1"
LIBCRYPTO="$BASE/openssl-1.1.1w/libcrypto.so.1.1"
LIBCOMPAT="$BASE/libssl_compat.so"
LIBCURL="$BASE/curl-7.88.1/lib/.libs/libcurl.so.4.8.0"
CURLBIN="$BASE/curl-7.88.1/src/.libs/curl"   # the command-line curl binary
CURLVER="1.0.1"   # curl-tls13: self-contained modern command-line curl (/usr/bin/curl11), App-Manager installable
BROWSERSERVER="$BASE/BrowserServer.bin"   # stock 3.0.5 BrowserServer (md5 $STOCK_BS_MD5)
NTPJOB="$BASE/ntpdate-sync"
NTPVER="1.1.2"   # ntpdate-sync: retry-until-success + IP fallbacks (DNS-at-boot fix), offline-root-aware postinst + pmPostInstall.script (App-Manager installable)

rm -rf "$OUT"; mkdir -p "$OUT"
TARFLAGS="--owner=0 --group=0 --numeric-owner -p"

pack_ipk() { # $1=builddir  $2=ipkname
  local b="$1" name="$2"
  printf '2.0\n' > "$b/debian-binary"
  ( cd "$b/control" && chmod 0755 p* 2>/dev/null || true; tar $TARFLAGS -czf ../control.tar.gz ./* )
  ( cd "$b/data"    && tar $TARFLAGS -czf ../data.tar.gz ./* )
  # The App-Manager path (Preware "install file" / WebOS Quick Install) runs
  # pmPostInstall.script / pmPreRemove.script as top-level ar members -- it does
  # NOT run the Debian postinst (that only runs via plain ipkg or Preware's
  # ipkgservice fallback). Ship copies as ar members so the package activates on
  # EVERY install path. (Long member names use the GNU // string table, which the
  # device's ar/ipkg accept; keep the 3 standard members first, in order.)
  local members="debian-binary control.tar.gz data.tar.gz"
  if [ -f "$b/control/postinst" ]; then cp "$b/control/postinst" "$b/pmPostInstall.script"; chmod 0755 "$b/pmPostInstall.script"; members="$members pmPostInstall.script"; fi
  if [ -f "$b/control/postrm" ];  then cp "$b/control/postrm"  "$b/pmPreRemove.script";   chmod 0755 "$b/pmPreRemove.script";   members="$members pmPreRemove.script"; fi
  ( cd "$b" && ar rc "$OUT/$name" $members )
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
# NOTE: the compat symlinks (libcurl.so.4, libssl.so.0.9.8, libcrypto.so.0.9.8)
# are intentionally NOT shipped in data.tar.gz. When Preware / WebOS Quick Install
# unpack into the app offline-root (/media/cryptofs/apps) that filesystem rejects
# symlink creation ("Operation not permitted"), which aborts the whole install.
# The postinst recreates these symlinks at the real /usr/lib/ssl11 instead.

# RPATH'd BrowserServer: bakes /usr/lib/ssl11 into DT_RPATH and adds the compat
# shim as NEEDED, so the browser loads the 1.1 stack regardless of which launcher
# starts it (upstart OR ls-hubd demand) and with no env vars. postinst swaps it in.
cp "$BROWSERSERVER" "$L/BrowserServer.rpath"
chmod 0755 "$L/BrowserServer.rpath"
patchelf --force-rpath --set-rpath /usr/lib/ssl11 "$L/BrowserServer.rpath"
patchelf --add-needed libssl_compat.so "$L/BrowserServer.rpath"
RPATH_BS_MD5=$(md5sum "$L/BrowserServer.rpath" | cut -d' ' -f1)   # so postinst never backs up our own binary as "stock"

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
 /usr/lib/ssl11 and swaps in an RPATH'd BrowserServer that loads the 1.1 stack
 with no environment variables. The two custom OpenSSL libs relocate ssl->ctx
 (0xD8) and X509_STORE_CTX->cert (0x8) to the offsets libWebKitLuna hardcodes,
 so the browser's cert callback works. The postinst is offline-root aware, so it
 installs correctly via Preware / WebOS Quick Install as well as plain ipkg.
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
RPATH_BS_MD5="$RPATH_BS_MD5"
EOF
cat >> "$B1/control/postinst" <<'EOF'

# Where ipkg actually put our payload. Preware and WebOS Quick Install install
# into the app offline-root (/media/cryptofs/apps) and run this script with
# IPKG_OFFLINE_ROOT set; a plain `ipkg install` leaves it empty and the files are
# already at their final location. Either way, make sure the real /usr/lib/ssl11
# ends up populated.
# When run as pmPostInstall.script (App-Manager path) IPKG_OFFLINE_ROOT is unset,
# but the payload is already unpacked under /media/cryptofs/apps -- adopt it.
[ -z "$IPKG_OFFLINE_ROOT" ] && [ -d /media/cryptofs/apps/usr/lib/ssl11 ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
SRC="${IPKG_OFFLINE_ROOT}/usr/lib/ssl11"

# -1. Materialize the real /usr/lib/ssl11. Under an offline install the libs live
#     in the sandbox (and the symlinks could not be unpacked there), so copy the
#     regular files into place ourselves.
if [ "$SRC" != "/usr/lib/ssl11" ] && [ -d "$SRC" ]; then
    mkdir -p /usr/lib/ssl11
    for f in libssl.so.1.1 libcrypto.so.1.1 libcurl.so.4.8.0 libssl_compat.so BrowserServer.rpath; do
        cp -f "$SRC/$f" "/usr/lib/ssl11/$f" && chmod 0755 "/usr/lib/ssl11/$f"
    done
fi

# 0a. (Re)create the compat symlinks at the real location. They are built here
#     rather than shipped in the package because the offline-root filesystem
#     rejects symlink creation during ipkg unpack.
ln -sf libcurl.so.4.8.0 /usr/lib/ssl11/libcurl.so.4
ln -sf libssl.so.1.1    /usr/lib/ssl11/libssl.so.0.9.8
ln -sf libcrypto.so.1.1 /usr/lib/ssl11/libcrypto.so.0.9.8

# 0b. remove stray upstart job-backups left by old (<=1.0.1) env-injection
#    installs. Upstart runs EVERY file in /etc/event.d as a job, so a leftover
#    browserserver.tls13-orig is a DUPLICATE launcher that fights the real one
#    for the bus name -> endless respawn churn -> pages stop loading.
rm -f /etc/event.d/*.tls13-orig /etc/event.d/*.orig /etc/event.d/*.preua /etc/event.d/*.pre-rpath 2>/dev/null

# 1. Back up the pre-existing BrowserServer so the package is cleanly
#    uninstallable, then swap in the RPATH'd build (loads /usr/lib/ssl11 with no
#    env, so it works regardless of which launcher starts it).
#    Make the backup ONCE: only when no backup exists yet AND the current binary
#    is not already our own RPATH'd build (so we never save our binary as if it
#    were stock, and never clobber a real backup across reinstalls/upgrades).
cur=$(md5sum /usr/bin/BrowserServer 2>/dev/null | cut -d' ' -f1)
if [ ! -f /usr/bin/BrowserServer.tls13-orig ] && [ "$cur" != "$RPATH_BS_MD5" ] && [ -f /usr/bin/BrowserServer ]; then
    cp -p /usr/bin/BrowserServer /usr/bin/BrowserServer.tls13-orig
    if [ "$cur" = "$STOCK_BS_MD5" ]; then
        echo "Backed up stock BrowserServer ($cur) to /usr/bin/BrowserServer.tls13-orig"
    else
        echo "NOTE: backed up a non-stock BrowserServer ($cur) as the uninstall restore point."
    fi
fi
if [ -f /usr/lib/ssl11/BrowserServer.rpath ]; then
    cp -f /usr/lib/ssl11/BrowserServer.rpath /usr/bin/BrowserServer
    chmod 755 /usr/bin/BrowserServer
else
    echo "ERROR: /usr/lib/ssl11/BrowserServer.rpath is missing; cannot enable modern TLS."
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
# Restore the stock BrowserServer. Only remove the ssl11 stack if we actually have
# the stock binary to fall back on -- otherwise the running BrowserServer is our
# RPATH'd one and deleting /usr/lib/ssl11 would leave it unable to load its libs
# (a dead browser). In that case leave the stack in place so the browser keeps working.
if [ -f /usr/bin/BrowserServer.tls13-orig ]; then
    mv -f /usr/bin/BrowserServer.tls13-orig /usr/bin/BrowserServer
    rm -rf /usr/lib/ssl11
else
    echo "WARNING: no /usr/bin/BrowserServer.tls13-orig backup found; keeping /usr/lib/ssl11"
    echo "         so the installed RPATH'd BrowserServer keeps working."
fi
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
Version: $NTPVER
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
 The postinst is offline-root aware so it also installs via Preware / WebOS
 Quick Install, not just plain ipkg.
EOF

cat > "$B2/control/preinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/postinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true

# Preware / WebOS Quick Install unpack into the app offline-root and run this
# script with IPKG_OFFLINE_ROOT set, so the upstart job lands in the sandbox
# (/media/cryptofs/apps/etc/event.d) where upstart never sees it. Copy it to the
# real /etc/event.d so the job actually registers. A plain `ipkg install` leaves
# IPKG_OFFLINE_ROOT empty and the file is already in place.
[ -z "$IPKG_OFFLINE_ROOT" ] && [ -f /media/cryptofs/apps/etc/event.d/ntpdate-sync ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
SRC="${IPKG_OFFLINE_ROOT}/etc/event.d/ntpdate-sync"
if [ "$SRC" != "/etc/event.d/ntpdate-sync" ] && [ -f "$SRC" ]; then
    cp -f "$SRC" /etc/event.d/ntpdate-sync
    chmod 0755 /etc/event.d/ntpdate-sync
fi

# (re)start the job
stop ntpdate-sync 2>/dev/null || true
start ntpdate-sync 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/prerm" <<'EOF'
#!/bin/sh
stop ntpdate-sync 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/postrm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop ntpdate-sync 2>/dev/null || true
# remove the job we copied to the real /etc/event.d (offline-root installs leave
# ipkg owning only the sandbox copy, so clean up the live one ourselves).
rm -f /etc/event.d/ntpdate-sync
exit 0
EOF
pack_ipk "$B2" "org.webosinternals.ntpdate-sync_${NTPVER}_${ARCH}.ipk"

############################################################################
# IPK 3: curl-tls13  -- self-contained modern command-line curl
############################################################################
B3="$OUT/_build_curl"
mkdir -p "$B3/control" "$B3/data/usr/lib/curl11" "$B3/data/usr/bin"
C="$B3/data/usr/lib/curl11"
install -m0755 "$CURLBIN"   "$C/curl"
install -m0755 "$LIBCURL"   "$C/libcurl.so.4.8.0"
install -m0755 "$LIBSSL"    "$C/libssl.so.1.1"
install -m0755 "$LIBCRYPTO" "$C/libcrypto.so.1.1"
# NOTE: the libcurl.so.4 symlink is created by the postinst, not shipped -- the
# offline-root filesystem (Preware/WOSQI) rejects symlink creation during unpack.

cat > "$B3/data/usr/bin/curl11" <<'EOF'
#!/bin/sh
exec env LD_LIBRARY_PATH=/usr/lib/curl11 /usr/lib/curl11/curl "$@"
EOF
chmod 0755 "$B3/data/usr/bin/curl11"

ISIZE3=$(du -sk "$B3/data" | cut -f1)000
cat > "$B3/control/control" <<EOF
Package: org.webosinternals.curl-tls13
Version: $CURLVER
Architecture: $ARCH
Maintainer: $MAINT
Section: misc
Priority: optional
Depends:
InstalledSize: $ISIZE3
Description: Modern command-line curl (7.88.1, TLS 1.2/1.3) for webOS TouchPad.
 Installs a self-contained curl 7.88.1 built against OpenSSL 1.1.1w + zlib under
 /usr/lib/curl11, exposed as the command /usr/bin/curl11 (a small wrapper that
 sets LD_LIBRARY_PATH). The stock /usr/bin/curl is left untouched. Use it as
 'curl11 https://...'. The postinst is offline-root aware, so it installs via
 Preware / WebOS Quick Install as well as plain ipkg.
EOF

cat > "$B3/control/preinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
exit 0
EOF

cat > "$B3/control/postinst" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true

# Preware / WebOS Quick Install unpack into the app offline-root and run this
# with IPKG_OFFLINE_ROOT set, so our files land in the sandbox. Copy them into
# the real tree (and create the libcurl.so.4 symlink, which can't be unpacked on
# the offline-root filesystem). A plain `ipkg install` leaves PFX empty and the
# files are already in place.
[ -z "$IPKG_OFFLINE_ROOT" ] && [ -d /media/cryptofs/apps/usr/lib/curl11 ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
PFX="${IPKG_OFFLINE_ROOT}"
if [ -n "$PFX" ] && [ -d "$PFX/usr/lib/curl11" ]; then
    mkdir -p /usr/lib/curl11
    for f in curl libcurl.so.4.8.0 libssl.so.1.1 libcrypto.so.1.1; do
        cp -f "$PFX/usr/lib/curl11/$f" "/usr/lib/curl11/$f" && chmod 0755 "/usr/lib/curl11/$f"
    done
    cp -f "$PFX/usr/bin/curl11" /usr/bin/curl11 && chmod 0755 /usr/bin/curl11
fi

# compat symlink at the real location
ln -sf libcurl.so.4.8.0 /usr/lib/curl11/libcurl.so.4
exit 0
EOF

cat > "$B3/control/prerm" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$B3/control/postrm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
rm -f /usr/bin/curl11
rm -rf /usr/lib/curl11
exit 0
EOF
pack_ipk "$B3" "org.webosinternals.curl-tls13_${CURLVER}_${ARCH}.ipk"

echo "=== output ==="
ls -l "$OUT"/*.ipk
