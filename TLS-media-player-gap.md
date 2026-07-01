# Why the TLS-1.3 patches broke HTML5 streaming media — and the one-line fix

**Status:** ✅ **RESOLVED 2026-07-01.** Ships in **`luna-tls13` 1.1.0**.
**Device:** HP TouchPad (`topaz`), webOS 3.0.5 and webOS CE 3.1.0, kernel 2.6.35-palm-tenderloin.
**Symptom:** After the TLS-1.3 upgrade, HTML5 `<audio class="media">` **streaming** apps
(`com.jmtk.apollo`, `com.drewksparks.pandora-tablet`, `com.palm.pandora`, Plex, drPodder) log in,
load stations, fetch the next track, `HEAD` the audio URL (200), set `player.src` — then **never
play**, timing out ("finding the next song" forever). **Local** media (stock Music, `file://`)
plays fine.

---

## TL;DR — root cause and fix

- The stock media worker **`/usr/bin/media-pipeline` is `fork()`+`exec()`'d by `WebAppMgr`** for
  each `<audio class=media>` element, and **inherits `WebAppMgr`'s env** — which the TLS patch set
  to `LD_PRELOAD=…/ssl11/libssl_compat.so` + `LD_LIBRARY_PATH=/usr/lib/ssl11`.
- With **lazy PLT binding** (the default), the worker **SIGSEGVs inside the glibc-2.8 dynamic
  linker** (`do_lookup_x`/`check_match`) the first time it resolves a symbol **across the 0.9.8→1.1
  OpenSSL shim**. It dies **before `gst_init` even runs** — the crash is *inside `ld.so`*, so it
  leaves **no PmLog line and no crash report**. The **network** startup path trips that symbol; the
  **local `file://`** path happens not to. Hence "Music plays, streaming spins forever."
- **This is the same bug — and the same fix — the mail transports already hit** (see the
  `mail-imap-smtp-WORKING` notes: intermittent ld.so lazy-binding SIGSEGV, fixed with
  `LD_BIND_NOW=1`).

### The fix — one line
`luna-tls13`'s launcher patch now adds, right after the ssl11 exports on `/etc/event.d/LunaSysMgr`:

```sh
export LD_BIND_NOW=1
```

Eager binding resolves every PLT symbol at load, in a controlled way, so the cross-shim lookup
never happens lazily mid-run. `WebAppMgr` **and every media worker it forks** inherit it.

**Proven on hardware (device B, ours-only):** with `LD_BIND_NOW=1`, Apollo logs in and plays;
gstreamer debug shows the real streaming pipeline building and reaching PLAYING:

```
souphttpsrc0 → httpidentity → httpqueue → aacparse0 → decodebin2 → pulsesink0
souphttpsrc0: start("http://audio-…-.pandora.com/access/…mp4?…token=…")  → PLAYING
```

Distribution: bump `luna-tls13` 1.0.0 → **1.1.0** and install on top (Preware / WebOS Quick
Install / ipkg). The postinst is **upgrade-safe** — on a launcher an older 1.0.0 already patched
with the ssl11 exports, it inserts *only* the `LD_BIND_NOW=1` line (no full re-patch), preserving
the `/var/luna/LunaSysMgr.tls13-orig` backup. **Reboot after install** (the upstart launcher edit
applies on the next LunaSysMgr start). Do **not** reinstall the same version number — package
managers skip a same-version install and the postinst never runs.

---

## What the earlier version of this document got WRONG

The prior investigation (dated 2026-06-29) concluded this was an **OpenSSL fork-safety** problem in
a **fork-only** worker. **Both conclusions were wrong.** Corrected by live investigation on
2026-07-01 (devices A = 3.0.5 + optware/nizovn, B = CE 3.1.0 ours-only):

- **The worker is `fork()`+`exec()` of `/usr/bin/media-pipeline`, NOT fork-only.** A live *playing*
  worker has `readlink /proc/<pid>/exe → /usr/bin/media-pipeline`, `cmdline = "media-pipeline
  MediaPlayer WebkitClient --gst-debug=1"`. The prior "wrapper was never hit ⇒ fork-only" reasoning
  was a false negative (its log went to a path not visible inside the media jail). Because it's
  `exec`, **fork-safety of inherited OpenSSL state does not apply** (exec resets the memory image).
- **It is NOT the gstreamer / TLS / streaming path.** `souphttpsrc → libsoup → **gnutls**` (libsoup
  uses gnutls, *not* OpenSSL) works perfectly under the full ssl11 env — verified with
  `gst-launch-0.10 souphttpsrc/playbin` on an `http://` Pandora-CDN URL: it connects, pulls
  headers, exits clean, identical to a clean env. And **Pandora audio is plain `http://`** — there
  is no TLS at the media layer at all. ⇒ **Do NOT "swap libgstreamer/libsoup for a TLS-1.3-aware
  one"** to fix this; it would change nothing. (A modern media-TLS stack is only relevant for a
  *separate* case: an app that streams media over `https`.)
- **It is NOT libcurl** — `media-pipeline`/`libmedia-api` link no curl and no OpenSSL directly.
- **It is NOT a symbol collision** — exported-symbol intersection of `libcrypto.so.1.1` with
  `libgcrypt.so.11` and `libgnutls.so.26` is **empty**, and `libssl_compat.so` exports only
  OpenSSL-prefixed names (no generic symbols that could interpose other libraries).
- **It is NOT nizovn / optware.** On device A, "nothing plays at all (even local Music)" was a
  *transient* `WebAppMgr` wedge caused by installing the nizovn **qt5sdk** under a never-rebooted
  `WebAppMgr`; a **reboot** restored local Music (streaming still failed). nizovn's separate
  SDK/jail is not in the media path.
- **No wrapper / env-scrub fix is possible on the worker.** Its Luna-service registration
  (`com.palm.mediad.MediaPlayer_<pid>` / `ManagedMediaResource_<pid>`, role
  `/usr/share/ls2/roles/{prv,pub}/com.palm.mediad.pipeline.json`) is **keyed to the exe path**
  `/usr/bin/media-pipeline`. Any wrapper that re-execs a differently-named real binary → the LS2
  hub returns **`-1027 Invalid permissions`** and the worker dies. That is *why* the fix is a
  launcher **env** change, not a binary/wrapper swap.

---

## How playback works (unchanged, still accurate)

All the streaming clients use HTML5 `<audio>` with the Palm `audioClass:"media"` extension. The two
network actions use two completely different stacks:

| Action | Who performs it | Stack |
|---|---|---|
| API calls + audio-URL `HEAD` check | App JS via `XMLHttpRequest` | WebKit/BrowserServer curl/OpenSSL path (fixed by the TLS patches — this works) |
| Actual audio fetch + decode | `<audio class=media>` → `WebAppMgr` forks `media-pipeline` | gstreamer path (`souphttpsrc`→decode→pulsesink) |

The app sets `player.src` to a plain `http://…mp4` (aacplus-adts), the `HEAD` returns 200, and then
`WebAppMgr` forks+execs a `media-pipeline` worker to fetch+decode. **That worker is what died** —
before `gst_init`, in `ld.so`, on the streaming path only.

---

## The evidence chain (what finally pinned it)

1. **Local vs network, same binary.** The persistent Music worker plays; each streaming attempt
   forks a fresh `media-pipeline` (ppid=`WebAppMgr`) that becomes a **zombie with no crash report
   and no `media-pipeline:` log line** — it never reached its first log or its `mediaserver`
   `ManagedMediaResource` session.
2. **`souphttpsrc` is innocent** — reproduced the full HTTP fetch under the worker's exact poisoned
   env via `gst-launch`; works.
3. **The decisive capture:** add `GST_DEBUG` + `GST_DEBUG_FILE=/media/internal/…` to the
   **`LunaSysMgr` launcher env** (NOT a wrapper — wrappers hit the LS2-role problem above), reboot,
   and read the worker's own gstreamer trace.
   - **Local (Music):** full `filesrc → typefind → decodebin2 → pulsesink` trace, NULL→READY→
     PAUSED→PLAYING.
   - **Streaming (Pandora):** the log stays **empty** for the network worker — it dies **before
     `gst_init`** writes a single line.
4. "Dies before `gst_init`, silently, no crash report, only on the network path" ⇒ a crash *inside
   the dynamic linker during lazy symbol resolution across the shim* — exactly the class the mail
   work fixed with `LD_BIND_NOW=1`. Applying it made streaming play. QED.

---

## Diagnostic playbook (reusable)

```sh
# Capture the REAL media worker's gstreamer trace (no wrapper — wrappers break its LS2 role):
#   edit /etc/event.d/LunaSysMgr, after the ssl11 exports add:
#       export GST_DEBUG="3,soup*:6,souphttpsrc:6,*sink*:6,pulsesink:6,dec*:5,GST_STATES:5"
#       export GST_DEBUG_FILE=/media/internal/gst-worker.log
#   (mount -o remount,rw / first; back up OUTSIDE /etc/event.d; reboot). Then play, and:
novacom get file:///media/internal/gst-worker.log > gst.log     # empty for the failing worker = dies pre-gst_init

# Confirm fork+exec (not fork-only): catch a live worker, read its exe:
readlink /proc/<pid>/exe        # /usr/bin/media-pipeline  ⇒ exec

# Prove souphttpsrc/gnutls is fine under the stack:
LD_PRELOAD="/usr/lib/libptmalloc3.so /usr/lib/libmemcpy.so /usr/lib/ssl11/libssl_compat.so" \
  LD_LIBRARY_PATH=/usr/lib/ssl11 gst-launch-0.10 souphttpsrc location=http://host/x.mp4 ! fakesink
```

**Gotchas that cost time here:** wrappers on `/usr/bin/media-pipeline` break its LS2 role (exe-path
keyed) → `-1027`; a `WebAppMgr` running since before a bad package install can be transiently
wedged (reboot to get a clean baseline); `/` remounts read-only on boot (`mount -o remount,rw /`);
never leave a backup file in `/etc/event.d/` (upstart runs every file there).
