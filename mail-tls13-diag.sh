#!/bin/sh
# mail-tls13-diag.sh -- verify mail-tls13 on-device and live-test an EAS sync.
#
# Usage (over novacom, per the repo's whitespace-splitting gotcha):
#   novacom put file:///tmp/mail-tls13-diag.sh < mail-tls13-diag.sh
#   novacom -- run file:///bin/sh /tmp/mail-tls13-diag.sh           # full check + live EAS test
#   novacom -- run file:///bin/sh /tmp/mail-tls13-diag.sh status    # static checks only
#
# Looks for a VERDICT line at the end. Read-only except for triggering a mail sync.
set -u
MODE="${1:-test}"
SSL11=/usr/lib/ssl11
MAILDIR=/usr/lib/ssl11mail
PASS=1
say() { echo "$@"; }
bad() { echo "  FAIL: $@"; PASS=0; }
ok()  { echo "  ok:   $@"; }

say "=== 1. ssl11 stack present (from browser-tls13) ==="
if [ -f "$SSL11/libssl.so.1.1" ] && [ -f "$SSL11/libssl_compat.so" ]; then
    ok "$SSL11 has libssl.so.1.1 + libssl_compat.so"
else
    bad "$SSL11 stack missing -- install org.webosinternals.browser-tls13 first"
fi

say "=== 2. libcurl-free redirect dir $MAILDIR ==="
if [ -d "$MAILDIR" ]; then
    for l in libssl.so.0.9.8 libcrypto.so.0.9.8 libssl.so.1.1 libcrypto.so.1.1 libssl_compat.so; do
        [ -e "$MAILDIR/$l" ] && ok "$l -> $(readlink "$MAILDIR/$l" 2>/dev/null)" || bad "missing $MAILDIR/$l"
    done
    if [ -e "$MAILDIR/libcurl.so.4" ] || [ -e "$MAILDIR/libcurl.so.4.8.0" ]; then
        bad "$MAILDIR contains libcurl -- it must NOT (would shadow stock 7.21.7 and crash)"
    else
        ok "no libcurl in $MAILDIR (stock libcurl 7.21.7 stays)"
    fi
else
    bad "$MAILDIR missing -- mail-tls13 not installed"
fi

say "=== 3. mojomail launchers patched ==="
for s in eas imap pop smtp; do
    F="/usr/share/dbus-1/system-services/com.palm.$s.service"
    [ -f "$F" ] || { say "  (com.palm.$s.service absent)"; continue; }
    if grep -q 'ssl11mail' "$F" 2>/dev/null; then ok "com.palm.$s.service patched"
    else say "  --    com.palm.$s.service NOT patched"; fi
done

say "=== 4. loader resolves mojomail-eas to ssl11 openssl + STOCK libcurl ==="
if [ -x /usr/bin/mojomail-eas ]; then
    LD_LIBRARY_PATH=$MAILDIR LD_PRELOAD=$MAILDIR/libssl_compat.so ldd /usr/bin/mojomail-eas 2>&1 \
      | grep -iE "libssl|libcrypto|libcurl|compat|not found" | sed 's/^/    /'
    nf=$(LD_LIBRARY_PATH=$MAILDIR LD_PRELOAD=$MAILDIR/libssl_compat.so ldd /usr/bin/mojomail-eas 2>&1 | grep -c "not found")
    [ "$nf" = 0 ] && ok "no unresolved symbols/libs" || bad "$nf unresolved -- shim/openssl gap"
    LD_LIBRARY_PATH=$MAILDIR LD_PRELOAD=$MAILDIR/libssl_compat.so ldd /usr/bin/mojomail-eas 2>&1 \
      | grep -q "libcurl.* /usr/lib/libcurl" && ok "libcurl resolves to STOCK /usr/lib" \
      || bad "libcurl is NOT the stock one -- crash risk"
fi

if [ "$MODE" = "status" ]; then
    echo; [ "$PASS" = 1 ] && echo "VERDICT: PASS (static checks)" || echo "VERDICT: FAIL (static checks)"
    exit 0
fi

say "=== 5. LIVE EAS sync test ==="
# discover the first EAS account + its Inbox folder
ACCT=$(luna-send -n 1 -a com.palm.app.email palm://com.palm.db/find '{"query":{"from":"com.palm.eas.account:1"}}' 2>/dev/null \
        | sed 's/.*"accountId":"//' | sed 's/".*//')
if [ -z "$ACCT" ]; then
    say "  (no EAS account configured -- skipping live test; add one or run with an IMAP account)"
    echo; [ "$PASS" = 1 ] && echo "VERDICT: PASS (static only; no account to live-test)" || echo "VERDICT: FAIL"
    exit 0
fi
INBOX=$(luna-send -n 1 -a com.palm.app.email palm://com.palm.db/find "{\"query\":{\"from\":\"com.palm.folder.eas:1\",\"where\":[{\"prop\":\"accountId\",\"op\":\"=\",\"val\":\"$ACCT\"}]}}" 2>/dev/null \
        | sed 's/.*"Inbox"[^}]*"_id":"//' | sed 's/".*//')
[ -z "$INBOX" ] && INBOX=$(luna-send -n 1 -a com.palm.app.email palm://com.palm.db/find "{\"query\":{\"from\":\"com.palm.folder.eas:1\",\"where\":[{\"prop\":\"accountId\",\"op\":\"=\",\"val\":\"$ACCT\"}]}}" 2>/dev/null | sed 's/.*"_id":"//' | sed 's/".*//')
say "  account=$ACCT inbox=$INBOX"

# mark log position, trigger sync, capture
SYNCED=$(luna-send -n 1 -a com.palm.app.email palm://com.palm.eas/syncFolder "{\"accountId\":\"$ACCT\",\"folderId\":\"$INBOX\",\"force\":true}" 2>&1)
say "  syncFolder -> $SYNCED"
say "  capturing 20s..."
sleep 20

CRASH=$(tail -n 500 /var/log/messages 2>/dev/null | grep -icE "mojomail-eas.*received 11|SIGSEGV.*mojomail-eas|curl_multi_remove_handle")
TLSERR=$(tail -n 500 /var/log/messages 2>/dev/null | grep -icE "com.palm.eas.*(certificate|handshake fail|ssl error|535|SSL_connect)")
ERRFIELD=$(luna-send -n 1 -a com.palm.app.email palm://com.palm.db/find '{"query":{"from":"com.palm.eas.account:1"}}' 2>/dev/null | grep -oE '"error":[^,]*' | head -1)

say "  crash hits=$CRASH  tls-error hits=$TLSERR  account $ERRFIELD"
if [ "$CRASH" != 0 ]; then bad "mojomail-eas crashed (libcurl/ssl) -- the fix did NOT hold"; fi
if [ "$TLSERR" != 0 ]; then bad "TLS/cert error during sync"; fi
if echo "$ERRFIELD" | grep -q '"error":null'; then ok "account error is null after sync"; else bad "account has an error set: $ERRFIELD"; fi

echo
if [ "$PASS" = 1 ] && [ "$CRASH" = 0 ]; then
    echo "VERDICT: PASS -- mojomail-eas ran on ssl11 OpenSSL with stock libcurl, no crash, no cert error."
else
    echo "VERDICT: FAIL -- see FAIL lines above. Recover: remove mail-tls13 (prerm restores launchers), or:"
    echo "  for s in eas imap pop smtp; do cp -f /var/luna/com.palm.\$s.service.tls13-orig /usr/share/dbus-1/system-services/com.palm.\$s.service; done; /usr/bin/ls-control scan-services; killall mojomail-eas mojomail-imap mojomail-pop mojomail-smtp"
fi
exit 0
