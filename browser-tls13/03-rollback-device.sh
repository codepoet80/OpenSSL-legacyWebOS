#!/bin/sh
#
# 03-rollback-device.sh  --  Undo 02-install-device.sh completely.  ON DEVICE, root.
#
# Because no binary or system library was ever modified (symlink-redirect
# approach), rollback is just: restore the upstart job(s), delete the private
# dir, restart.  The OS returns to its exact pre-install state on 0.9.8.
#
# The modern CA bundle is LEFT in place by default (you almost certainly want to
# keep it). Pass --restore-stock-ca to revert the cert bundle too.
#
set -e

echo "== restore browser upstart job(s) =="
for job in /etc/event.d/browserserver /etc/event.d/browserservermojo; do
    if [ -f "$job.orig" ]; then mv -f "$job.orig" "$job"; echo "  restored: $job"; fi
done

echo "== remove private lib dir =="
rm -rf /usr/lib/ssl11
echo "  removed: /usr/lib/ssl11"

# stale artifact from the earlier patchelf-era install, if present (BrowserServer
# was never modified in the symlink approach, so this .orig is redundant)
[ -f /usr/bin/BrowserServer.orig ] && rm -f /usr/bin/BrowserServer.orig

if [ "${1:-}" = "--restore-stock-ca" ] && [ -f /etc/ssl/certs/ca-certificates.crt.stock2011 ]; then
    mv -f /etc/ssl/certs/ca-certificates.crt.stock2011 /etc/ssl/certs/ca-certificates.crt
    echo "== restored stock 2011 CA bundle =="
fi

echo "== restart browser =="
stop browserserver 2>/dev/null || true
start browserserver 2>/dev/null || true

echo
echo "DONE. Browser is back on the original 0.9.8 stack. (No binary/system lib was ever altered.)"
