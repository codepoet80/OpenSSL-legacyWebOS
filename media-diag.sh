#!/bin/sh
# luna-tls13 1.1.1 media-fix diagnostic -- READ-ONLY, safe on any device (incl. daily driver).
# Push + run:  novacom -d <NDUID> put file:///tmp/media-diag.sh < media-diag.sh
#              novacom -d <NDUID> -- run file:///bin/sh /tmp/media-diag.sh
WRAP_MD5=ce9e19494f4cd73b47ad1d9dff059aec       # the 1.1.1 wrapper
STOCK_MD5=37d4e61606e80dfe49131eca2a68e83a      # stock media-pipeline on 3.0.5 (differs on CE 3.1.0 -- OK)

echo "===== luna-tls13 1.1.1 media-fix diagnostic ====="
echo "--- wrapper layout ---"
ls -la /usr/bin/media-pipeline* 2>&1
echo "media-pipeline md5: $(md5sum /usr/bin/media-pipeline 2>/dev/null | cut -d' ' -f1)  (wrapper=$WRAP_MD5)"
echo ".real         md5: $(md5sum /usr/bin/media-pipeline.real 2>/dev/null | cut -d' ' -f1)  (3.0.5 stock=$STOCK_MD5; CE3.1.0 differs)"
echo "sizes: media-pipeline=$(wc -c < /usr/bin/media-pipeline 2>/dev/null)  .real=$(wc -c < /usr/bin/media-pipeline.real 2>/dev/null)  (wrapper is the small one, ~458K)"

echo "--- .real LS2 roles (both should be present) ---"
for d in prv pub; do
  f=/usr/share/ls2/roles/$d/com.palm.mediad.pipeline.real.json
  [ -f "$f" ] && echo "  $f : $(grep exeName "$f" | tr -d ' ')" || echo "  $f : MISSING"
done

echo "--- stock backup ---"
ls -la /var/luna/media-pipeline.stock-orig 2>/dev/null || echo "  (no /var/luna/media-pipeline.stock-orig)"

echo "--- workers this boot that reached PLAYING (do some playback first; expect several) ---"
grep 'media-pipeline:' /var/log/messages 2>/dev/null | grep -c 'is now PLAYING'
echo "--- recent worker loads (what was played) ---"
grep 'media-pipeline:' /var/log/messages 2>/dev/null | grep 'load:' | sed 's/.*load: //' | tail -6

echo "--- LIVE workers (expect exe=/usr/bin/media-pipeline.real, ssl11=0) ---"
found=0
for p in /proc/[0-9]*; do
  pid=${p#/proc/}; l=$(cat $p/stat 2>/dev/null) || continue
  case "$l" in *'(media-pipeline'*)
    found=1
    echo "  pid=$pid exe=[$(readlink /proc/$pid/exe 2>/dev/null)] ssl11_in_maps=$(grep -c ssl11 /proc/$pid/maps 2>/dev/null)"
  ;; esac
done
[ "$found" = 0 ] && echo "  (no live media worker right now -- start playback, then re-run)"

echo "--- errors this boot (ALL of these should be empty) ---"
grep -iE 'No role file for|Invalid permission|-1027' /var/log/messages 2>/dev/null | grep -i media | tail -4
echo "transport.c:1895 (harmless if present -- it's benign teardown noise): $(grep 'media-pipeline:' /var/log/messages 2>/dev/null | grep -c 'transport.c:1895')"

echo "--- context ---"
echo "nizovn apps installed: $(ls /media/cryptofs/apps/usr/palm/applications 2>/dev/null | grep -ic nizovn)"
echo "launcher ssl11+LD_BIND_NOW lines (expect 3 once luna is applied): $(grep -cE 'ssl11/libssl_compat|LD_LIBRARY_PATH=/usr/lib/ssl11|LD_BIND_NOW=1' /etc/event.d/LunaSysMgr 2>/dev/null)"
echo "===== end ====="