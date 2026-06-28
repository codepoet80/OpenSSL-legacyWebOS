# Changes to mojomail

This is the exhaustive list of changes this project makes to **mojomail itself** (the stock
webOS native mail transports `mojomail-eas` / `mojomail-imap` / `mojomail-pop` /
`mojomail-smtp`). There is exactly one, and it ships in its **own standalone, optional ipk**
(`org.webosinternals.mojomail-imap-tagfix`) — deliberately kept **separate from
`mail-tls13`** so it can be taken or left independently and won't collide with anyone else's
mojomail patches.

Everything the `mail-tls13` TLS package does — the `/usr/lib/ssl11mail` libraries (our libcurl
+ `libssl_compat.so`), the four D-Bus `*.service` launcher env prefixes (`LD_LIBRARY_PATH`,
`LD_PRELOAD`, `LD_BIND_NOW=1`, `CURL_CA_BUNDLE`, `SSL_CERT_FILE`) — lives *outside* mojomail and
is described in [BUILDING.md](BUILDING.md). Those are not changes to mojomail and are not
listed here. (`LD_BIND_NOW=1` changes how mojomail is *launched*, not the binaries.)

## The one and only change: a 1-byte patch to `mojomail-imap`

| | |
|---|---|
| Binary | `/usr/bin/mojomail-imap` (stock webOS 3.0.5) |
| Stock md5 | `9f6489ae48fc131733c1a88a9aa1056a` |
| Patched md5 | `78956f6daf374a9a940e914459f234c3` |
| File offset | `991784` (`0xf2228`) |
| Byte before | `0x7e` (`~`) |
| Byte after | `0x41` (`A`) |
| Size | unchanged (1643847 bytes) |

That single byte is the first character of mojomail's hard-coded **IMAP command tag prefix**,
changing it from `~A` to `AA`. So every IMAP command tag mojomail emits goes from `~A1`,
`~A2`, … to `AA1`, `AA2`, …

### Why

mojomail tags each IMAP command with a `~`-leading string. In the mojomail source this is:

```cpp
// imap/src/client/ImapRequestManager.cpp  (SendRequest)
// Create tag prefixed by "~A" from the current request id counter
ss << "~A" << id;                 // e.g. tag "~A1"
// ... ss << " " << request << "\r\n";   ->  "~A1 CAPABILITY\r\n"
```

`~` (0x7e) is a legal IMAP tag character per RFC 3501, and 2011-era servers accepted it. But
**strict modern servers (e.g. Fastmail) reject any tag containing `~`** — they can't parse
the line into tag + command and answer with an *untagged* `* BAD invalid command`. mojomail
is waiting for a reply tagged `~A1`, never sees one, and times out after 30 s
(`LineReader.cpp` → mojomail error **3099**, "timeout exceeded reading line"). Proven with
`openssl s_client` to `imap.fastmail.com:993`: `AA1 CAPABILITY` → `AA1 OK completed`, while
`~A1 CAPABILITY` → `* BAD invalid command`.

The patch makes the tag `AA…`, which is valid on every server (old and new), so it is strictly
an improvement and breaks nothing.

### How it's packaged, applied, and reverted

It ships as `org.webosinternals.mojomail-imap-tagfix` — a tiny, standalone ipk with **no
payload and no dependencies**; it patches the on-device binary in its postinst and restores it
in its prerm. No binary is redistributed.

- **postinst:** if `/usr/bin/mojomail-imap`'s md5 is the known stock value
  (`9f6489…`), back it up to `/var/luna/mojomail-imap.tagfix-orig`, copy it to a
  same-filesystem temp, write byte `0x41` at offset `991784`, verify the md5 is the expected
  patched value (`78956f…`), then `mv` the temp over the original (an in-place `dd` would fail
  `ETXTBSY` because the binary is running; `mv`/rename replaces the directory entry safely). If
  the md5 is **unrecognized** — a different mojomail build, or someone else's mojomail patch is
  already installed — it does **nothing** (logs a note) rather than corrupt an unknown binary.
- **prerm:** restores `/usr/bin/mojomail-imap` from the `/var/luna` backup.

Installing/removing it is fully independent of `mail-tls13`. (It's only *useful* alongside
`mail-tls13`, which gives the IMAP transport modern TLS in the first place — but they are not
coupled.)

### Source-level equivalent (for rebuilding mojomail instead of binary-patching)

If you build mojomail from source, make the identical change in
`imap/src/client/ImapRequestManager.cpp`:

```diff
- ss << "~A" << id;
+ ss << "AA" << id;
```

(Keeping a 2-character prefix matches the binary patch exactly. Any non-`~`, RFC-valid tag
prefix works.)

## Unchanged

`mojomail-eas`, `mojomail-pop`, and `mojomail-smtp` binaries are **not modified**. EAS, POP,
and SMTP work on the modern stack with no mojomail change at all — only the external libraries
and launcher env (see [BUILDING.md](BUILDING.md)).
