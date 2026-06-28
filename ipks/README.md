# Modern TLS ipks — install order

Install via **Preware** / **WebOS Quick Install** / `ipkg install`, in this order:

1. `org.webosinternals.browser-tls13` — browser TLS 1.3 (provides `/usr/lib/ssl11`; **install first**)
2. `org.webosinternals.luna-tls13` — apps (Mojo/Enyo WebKit) TLS 1.3 (**requires #1**)
3. `org.webosinternals.curl-tls13` — modern `curl` / `curl11`
4. `org.webosinternals.ntpdate-sync` — clock sync

Then **reboot once**.

Optional packages — modern TLS for the stock Email app:

5. `org.webosinternals.mail-tls13` — mail transports on TLS 1.2/1.3 (**requires #1**; no
   reboot). **EAS, IMAP & SMTP all working & hardware-proven**; POP in
   testing. Details: [BUILDING.md](../BUILDING.md).
6. `org.webosinternals.mojomail-imap-tagfix` — **optional, standalone**: a one-byte
   `mojomail-imap` patch so strict IMAP servers (e.g. Fastmail) accept its command tags. Only
   needed for such servers; pairs with #5; reversible. Details:
   [mojomail-changes.md](../mojomail-changes.md).

Full details — requirements, what it does/doesn't do, verification, recovery, and how
it works — are in the [project README](../README.md). Building: [BUILDING.md](../BUILDING.md).
