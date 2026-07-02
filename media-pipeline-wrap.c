/* media-pipeline env-scrub wrapper  (org.webosinternals.luna-tls13)
 * ---------------------------------------------------------------------------
 * The webOS HTML5 media worker, /usr/bin/media-pipeline, is fork+exec'd by
 * WebAppMgr and inherits WebAppMgr's environment.  luna-tls13 puts an ssl11
 * OpenSSL-1.1 stack into that environment (LD_PRELOAD=.../libssl_compat.so,
 * LD_LIBRARY_PATH=/usr/lib/ssl11, LD_BIND_NOW=1) so the app WebKit can do
 * TLS 1.2/1.3.  The media worker, however, never needed OpenSSL at all --
 * local files don't touch it and http(s) streaming goes through libsoup ->
 * gnutls, not our OpenSSL.  That inherited-but-unused stack corrupts the
 * worker's teardown, so after the first track the media subsystem WEDGES:
 * one song plays, then the next worker dies at init and the play button goes
 * no-op until a Luna restart (hit Pandora/Plex/drPodder AND stock Music).
 *
 * Fix: this wrapper is installed AS /usr/bin/media-pipeline; the real binary
 * is moved aside to /usr/bin/media-pipeline.real.  Each time WebAppMgr spawns
 * a worker, the wrapper restores the stock environment (the two stock webOS
 * preloads, minus libssl_compat; no ssl11 lib path; no forced eager binding)
 * and exec's the real binary -- so the worker runs exactly as it did for the
 * 15 years before the TLS stack existed, while WebKit keeps full TLS.
 *
 * The moved-aside binary is given its own luna-service2 role
 * (com.palm.mediad.pipeline.real) so its MediaPlayer_<pid> registration is
 * still authorized (LS2 roles are keyed to the exe path).
 *
 * Static ELF: no shared-lib dependencies, so it runs inside the media jail
 * (which bind-mounts /usr/bin read-only) with nothing else required.
 */
#include <unistd.h>
#include <stdlib.h>

/* Retained literal so the installer can positively identify an already-wrapped
 * media-pipeline regardless of the wrapper's md5 (which changes if recompiled). */
__attribute__((used))
static const char wrap_marker[] = "webos-tls13-media-pipeline-envscrub-wrapper";

int main(int argc, char **argv)
{
    (void)argc;
    /* stock webOS 3.0.5 preload set, with our libssl_compat.so removed */
    setenv("LD_PRELOAD", "/usr/lib/libptmalloc3.so /usr/lib/libmemcpy.so", 1);
    /* our additions -- the stock worker had neither */
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("LD_BIND_NOW");

    execv("/usr/bin/media-pipeline.real", argv);
    _exit(127);   /* only reached if exec fails */
}
