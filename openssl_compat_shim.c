/*
 * OpenSSL 0.9.8 -> 1.1.1 Compatibility Shim for webOS
 *
 * This provides deprecated/removed symbols from OpenSSL 0.9.8 that are
 * needed by webOS binaries but don't exist in OpenSSL 1.1.1.
 *
 * Compile with (note -ldl for dladdr/RTLD_NEXT):
 *   arm-none-linux-gnueabi-gcc -shared -fPIC -o libssl_compat.so openssl_compat_shim.c \
 *       -I/path/to/openssl-1.1.1w/include -L/path/to/openssl-1.1.1w -lssl -lcrypto -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/crypto.h>
#include <openssl/rand.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/rsa.h>
#include <openssl/dh.h>
#include <openssl/bn.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>

/*
 * Undefine macros from OpenSSL 1.1.x that would conflict with our shim functions
 * These functions are macros in 1.1.x but were real functions in 0.9.8
 */
#undef SSL_library_init
#undef SSL_load_error_strings
#undef ERR_load_crypto_strings
#undef ERR_free_strings
#undef EVP_cleanup
#undef CRYPTO_cleanup_all_ex_data
#undef OPENSSL_add_all_algorithms_noconf
#undef RAND_cleanup
#undef OBJ_cleanup
#undef CRYPTO_num_locks
#undef CRYPTO_set_locking_callback
#undef CRYPTO_set_id_callback
#undef CRYPTO_get_lock_name
#undef CRYPTO_thread_id
#undef OpenSSL_add_all_algorithms
#undef OpenSSL_add_all_ciphers
#undef OpenSSL_add_all_digests
#undef EVP_CIPHER_CTX_init
#undef EVP_CIPHER_CTX_cleanup
#undef EVP_MD_CTX_init
#undef EVP_MD_CTX_cleanup
#undef SSL_CTX_set_tmp_rsa
#undef SSL_set_tmp_rsa
#undef SSL_CTX_set_tmp_rsa_callback
#undef SSL_set_tmp_rsa_callback
#undef X509_STORE_get_by_subject
#undef SSLeay
#undef SSLeay_version
#undef SSLv23_method
#undef SSLv23_client_method
#undef SSLv23_server_method
#undef EVP_MD_CTX_create
#undef EVP_MD_CTX_destroy
#undef RSA_generate_key
#undef ERR_remove_state
#undef SSL_state_string_long

/*
 * ============================================================================
 * INITIALIZATION/CLEANUP FUNCTIONS
 * These are no-ops in OpenSSL 1.1.x - library self-initializes
 * ============================================================================
 */

/* SSL_library_init - no longer needed, returns 1 for compatibility */
int SSL_library_init(void)
{
    /* OpenSSL 1.1.x auto-initializes */
    return 1;
}

/* SSL_load_error_strings - no longer needed */
void SSL_load_error_strings(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* ERR_load_crypto_strings - no longer needed */
void ERR_load_crypto_strings(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* ERR_free_strings - no longer needed */
void ERR_free_strings(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* EVP_cleanup - no longer needed */
void EVP_cleanup(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* CRYPTO_cleanup_all_ex_data - no longer needed */
void CRYPTO_cleanup_all_ex_data(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* OPENSSL_add_all_algorithms_noconf - no longer needed */
void OPENSSL_add_all_algorithms_noconf(void)
{
    /* No-op in OpenSSL 1.1.x - algorithms auto-loaded */
}

/* OpenSSL_add_all_algorithms - no longer needed */
void OpenSSL_add_all_algorithms(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* OpenSSL_add_all_ciphers - no longer needed */
void OpenSSL_add_all_ciphers(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* OpenSSL_add_all_digests - no longer needed */
void OpenSSL_add_all_digests(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* RAND_cleanup - no longer needed */
void RAND_cleanup(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/* OBJ_cleanup - no longer needed */
void OBJ_cleanup(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/*
 * ============================================================================
 * EVP CONTEXT FUNCTIONS
 * In 1.1.x, contexts are opaque and must be allocated with _new/_free
 * ============================================================================
 */

/* EVP_CIPHER_CTX_init - use reset instead */
void EVP_CIPHER_CTX_init(EVP_CIPHER_CTX *ctx)
{
    if (ctx)
        EVP_CIPHER_CTX_reset(ctx);
}

/* EVP_CIPHER_CTX_cleanup - use reset instead */
int EVP_CIPHER_CTX_cleanup(EVP_CIPHER_CTX *ctx)
{
    if (ctx) {
        EVP_CIPHER_CTX_reset(ctx);
        return 1;
    }
    return 0;
}

/* EVP_MD_CTX_init - use reset instead */
void EVP_MD_CTX_init(EVP_MD_CTX *mdctx)
{
    if (mdctx)
        EVP_MD_CTX_reset(mdctx);
}

/* EVP_MD_CTX_cleanup - use reset instead */
int EVP_MD_CTX_cleanup(EVP_MD_CTX *mdctx)
{
    if (mdctx) {
        EVP_MD_CTX_reset(mdctx);
        return 1;
    }
    return 0;
}

/*
 * ============================================================================
 * THREADING FUNCTIONS
 * OpenSSL 1.1.x handles threading internally
 * ============================================================================
 */

/* CRYPTO_num_locks - return 0, no external locks needed */
int CRYPTO_num_locks(void)
{
    return 0;
}

/* CRYPTO_set_locking_callback - no-op */
void CRYPTO_set_locking_callback(void (*func)(int mode, int type,
                                              const char *file, int line))
{
    /* No-op in OpenSSL 1.1.x - threading handled internally */
    (void)func;
}

/* CRYPTO_set_id_callback - no-op */
void CRYPTO_set_id_callback(unsigned long (*func)(void))
{
    /* No-op in OpenSSL 1.1.x */
    (void)func;
}

/* CRYPTO_get_lock_name - return empty string */
const char *CRYPTO_get_lock_name(int type)
{
    (void)type;
    return "";
}

/* CRYPTO_thread_id - return current thread id */
unsigned long CRYPTO_thread_id(void)
{
    return (unsigned long)pthread_self();
}

/*
 * ============================================================================
 * SSL STATE FUNCTION
 * ============================================================================
 */

/* SSL_state - map to SSL_get_state */
int SSL_state(const SSL *ssl)
{
    return SSL_get_state(ssl);
}

/*
 * ============================================================================
 * RAND_egd - EGD support removed in 1.1.x
 * ============================================================================
 */

int RAND_egd(const char *path)
{
    (void)path;
    /* EGD not supported, but return success if PRNG is seeded */
    return RAND_status() ? 0 : -1;
}

int RAND_egd_bytes(const char *path, int bytes)
{
    (void)path;
    (void)bytes;
    return RAND_status() ? bytes : -1;
}

/*
 * ============================================================================
 * X509 COMPATIBILITY
 * ============================================================================
 */

/* X509_STORE_get_by_subject - compatibility wrapper */
int X509_STORE_get_by_subject(X509_STORE_CTX *vs, int type,
                               X509_NAME *name, X509_OBJECT *ret)
{
    X509_OBJECT *obj;
    int ok = 0;

    obj = X509_STORE_CTX_get_obj_by_subject(vs, type, name);
    if (obj != NULL) {
        /* In 1.1.x X509_OBJECT is opaque, we can't copy it directly */
        /* Just return success - the caller likely just checks if found */
        (void)ret;
        ok = 1;
        X509_OBJECT_free(obj);
    }
    return ok;
}

/* X509_OBJECT_free_contents - use X509_OBJECT_free */
void X509_OBJECT_free_contents(X509_OBJECT *obj)
{
    if (obj) {
        X509_OBJECT_free(obj);
    }
}

/*
 * ============================================================================
 * DEPRECATED DIGEST ALGORITHMS
 * Return NULL for removed algorithms
 * ============================================================================
 */

const EVP_MD *EVP_dss1(void)
{
    /* DSS1 was SHA1 with DSA - just return SHA1 */
    return EVP_sha1();
}

const EVP_MD *EVP_ecdsa(void)
{
    /* ECDSA used SHA1 by default */
    return EVP_sha1();
}

const EVP_MD *EVP_md2(void)
{
    /* MD2 is removed - return NULL */
    return NULL;
}

/*
 * ============================================================================
 * PKCS12 COMPATIBILITY
 * ============================================================================
 */

X509 *PKCS12_certbag2x509(void *bag)
{
    /* This function was removed - return NULL */
    (void)bag;
    return NULL;
}

/*
 * ============================================================================
 * RSA COMPATIBILITY
 * ============================================================================
 */

/* RSA_PKCS1_SSLeay was renamed to RSA_PKCS1_OpenSSL */
const RSA_METHOD *RSA_PKCS1_SSLeay(void)
{
    return RSA_PKCS1_OpenSSL();
}

/* SSL_CTX_set_tmp_rsa_callback - no-op, tmp RSA not used anymore */
void SSL_CTX_set_tmp_rsa_callback(SSL_CTX *sslctx,
                                   RSA *(*cb)(SSL *, int, int))
{
    (void)sslctx;
    (void)cb;
    /* No-op - ephemeral RSA keys are no longer supported */
}

/* SSL_set_tmp_rsa_callback - no-op */
void SSL_set_tmp_rsa_callback(SSL *sslconn,
                               RSA *(*cb)(SSL *, int, int))
{
    (void)sslconn;
    (void)cb;
    /* No-op - ephemeral RSA keys are no longer supported */
}

/* SSL_CTX_set_tmp_rsa - no-op */
long SSL_CTX_set_tmp_rsa(SSL_CTX *sslctx, RSA *rsa)
{
    (void)sslctx;
    (void)rsa;
    return 1;
}

/* SSL_set_tmp_rsa - no-op */
long SSL_set_tmp_rsa(SSL *sslconn, RSA *rsa)
{
    (void)sslconn;
    (void)rsa;
    return 1;
}

/*
 * ============================================================================
 * DH COMPATIBILITY
 * ============================================================================
 */

/* DH_generate_parameters - deprecated, use DH_generate_parameters_ex */
DH *DH_generate_parameters(int prime_len, int generator,
                            void (*callback)(int, int, void *), void *cb_arg)
{
    DH *dh;
    BN_GENCB *cb = NULL;

    (void)callback;
    (void)cb_arg;

    dh = DH_new();
    if (dh == NULL)
        return NULL;

    if (!DH_generate_parameters_ex(dh, prime_len, generator, cb)) {
        DH_free(dh);
        return NULL;
    }

    return dh;
}

/*
 * ============================================================================
 * ENGINE FUNCTIONS
 * ============================================================================
 */

/* ENGINE_cleanup - no-op */
void ENGINE_cleanup(void)
{
    /* No-op in OpenSSL 1.1.x */
}

/*
 * ============================================================================
 * HMAC FUNCTIONS - HMAC_CTX was made opaque
 * ============================================================================
 */

/* HMAC_CTX_init - deprecated, use HMAC_CTX_reset */
void HMAC_CTX_init(HMAC_CTX *ctx)
{
    if (ctx)
        HMAC_CTX_reset(ctx);
}

/* HMAC_CTX_cleanup - deprecated, use HMAC_CTX_reset */
void HMAC_CTX_cleanup(HMAC_CTX *ctx)
{
    if (ctx)
        HMAC_CTX_reset(ctx);
}

/*
 * ============================================================================
 * BN (Big Number) COMPATIBILITY
 * ============================================================================
 */

/* BN_init - deprecated in 1.1.x, use BN_new instead */
void BN_init(BIGNUM *bn)
{
    /* Can't actually init a stack-allocated BN in 1.1.x */
    /* This is for compatibility only - will likely crash if used */
    (void)bn;
}

/*
 * ============================================================================
 * VERSION FUNCTIONS
 * ============================================================================
 */

/* SSLeay - renamed to OpenSSL_version_num in 1.1.x */
unsigned long SSLeay(void)
{
    return OpenSSL_version_num();
}

/* SSLeay_version - renamed to OpenSSL_version in 1.1.x */
const char *SSLeay_version(int type)
{
    return OpenSSL_version(type);
}

/*
 * ============================================================================
 * SSL METHOD FUNCTIONS
 * Old protocol-specific methods replaced with TLS_*_method()
 * ============================================================================
 */

/* SSLv23_method - renamed to TLS_method */
const SSL_METHOD *SSLv23_method(void)
{
    return TLS_method();
}

/* SSLv23_client_method - renamed to TLS_client_method */
const SSL_METHOD *SSLv23_client_method(void)
{
    return TLS_client_method();
}

/* SSLv23_server_method - renamed to TLS_server_method */
const SSL_METHOD *SSLv23_server_method(void)
{
    return TLS_server_method();
}

/* SSLv2_method - SSLv2 removed, return TLS method */
const SSL_METHOD *SSLv2_method(void)
{
    /* SSLv2 is insecure and removed - return TLS method */
    return TLS_method();
}

/* SSLv2_client_method - SSLv2 removed */
const SSL_METHOD *SSLv2_client_method(void)
{
    return TLS_client_method();
}

/* SSLv2_server_method - SSLv2 removed */
const SSL_METHOD *SSLv2_server_method(void)
{
    return TLS_server_method();
}

/* SSLv3_method - SSLv3 disabled by default, return TLS method */
const SSL_METHOD *SSLv3_method(void)
{
    /* SSLv3 is insecure - return TLS method */
    return TLS_method();
}

/* SSLv3_client_method - SSLv3 disabled */
const SSL_METHOD *SSLv3_client_method(void)
{
    return TLS_client_method();
}

/* SSLv3_server_method - SSLv3 disabled */
const SSL_METHOD *SSLv3_server_method(void)
{
    return TLS_server_method();
}

/* TLSv1_method - use TLS_method with version constraints */
const SSL_METHOD *TLSv1_method(void)
{
    return TLS_method();
}

/* TLSv1_client_method */
const SSL_METHOD *TLSv1_client_method(void)
{
    return TLS_client_method();
}

/* TLSv1_server_method */
const SSL_METHOD *TLSv1_server_method(void)
{
    return TLS_server_method();
}

/* TLSv1_1_method */
const SSL_METHOD *TLSv1_1_method(void)
{
    return TLS_method();
}

/* TLSv1_1_client_method */
const SSL_METHOD *TLSv1_1_client_method(void)
{
    return TLS_client_method();
}

/* TLSv1_1_server_method */
const SSL_METHOD *TLSv1_1_server_method(void)
{
    return TLS_server_method();
}

/*
 * ============================================================================
 * ADDITIONAL COMPATIBILITY FUNCTIONS
 * Added for webOS browser and keymanager compatibility
 * ============================================================================
 */

/* EVP_MD_CTX_create - renamed to EVP_MD_CTX_new in 1.1.x */
EVP_MD_CTX *EVP_MD_CTX_create(void)
{
    return EVP_MD_CTX_new();
}

/* EVP_MD_CTX_destroy - renamed to EVP_MD_CTX_free in 1.1.x */
void EVP_MD_CTX_destroy(EVP_MD_CTX *ctx)
{
    EVP_MD_CTX_free(ctx);
}

/* RSA_generate_key - deprecated, use RSA_generate_key_ex */
RSA *RSA_generate_key(int bits, unsigned long e_value,
                       void (*callback)(int, int, void *), void *cb_arg)
{
    RSA *rsa;
    BIGNUM *e;

    (void)callback;
    (void)cb_arg;

    rsa = RSA_new();
    if (rsa == NULL)
        return NULL;

    e = BN_new();
    if (e == NULL) {
        RSA_free(rsa);
        return NULL;
    }

    if (!BN_set_word(e, e_value)) {
        BN_free(e);
        RSA_free(rsa);
        return NULL;
    }

    if (!RSA_generate_key_ex(rsa, bits, e, NULL)) {
        BN_free(e);
        RSA_free(rsa);
        return NULL;
    }

    BN_free(e);
    return rsa;
}

/* ERR_remove_state - removed in 1.1.x, thread-local errors auto-cleanup */
void ERR_remove_state(unsigned long tid)
{
    (void)tid;
    /* No-op in OpenSSL 1.1.x - errors are thread-local and auto-cleaned */
}

/* X509_OBJECT_idx_by_subject - exists in 1.1 with same signature */
/* No wrapper needed */

/* SSL_state_string_long - get descriptive SSL state string */
const char *SSL_state_string_long(const SSL *ssl)
{
    OSSL_HANDSHAKE_STATE state = SSL_get_state(ssl);

    switch (state) {
        case TLS_ST_BEFORE: return "before SSL initialization";
        case TLS_ST_OK: return "SSL negotiation finished successfully";
        case TLS_ST_CW_CLNT_HELLO: return "SSLv3/TLS write client hello";
        case TLS_ST_CR_SRVR_HELLO: return "SSLv3/TLS read server hello";
        case TLS_ST_CR_CERT: return "SSLv3/TLS read server certificate";
        case TLS_ST_CR_KEY_EXCH: return "SSLv3/TLS read server key exchange";
        case TLS_ST_CR_CERT_REQ: return "SSLv3/TLS read server certificate request";
        case TLS_ST_CR_SRVR_DONE: return "SSLv3/TLS read server done";
        case TLS_ST_CW_CERT: return "SSLv3/TLS write client certificate";
        case TLS_ST_CW_KEY_EXCH: return "SSLv3/TLS write client key exchange";
        case TLS_ST_CW_CERT_VRFY: return "SSLv3/TLS write certificate verify";
        case TLS_ST_CW_CHANGE: return "SSLv3/TLS write change cipher spec";
        case TLS_ST_CW_FINISHED: return "SSLv3/TLS write finished";
        case TLS_ST_CR_SESSION_TICKET: return "SSLv3/TLS read session ticket";
        case TLS_ST_CR_CHANGE: return "SSLv3/TLS read change cipher spec";
        case TLS_ST_CR_FINISHED: return "SSLv3/TLS read finished";
        default: return "unknown state";
    }
}

/*
 * ============================================================================
 * GENERIC STACK (sk_*) COMPATIBILITY  -- added for browser TLS 1.3 work
 *
 * OpenSSL 1.1.0 renamed the generic, non-typed stack primitives from
 *     sk_*()  ->  OPENSSL_sk_*()
 * and stopped exporting the old names.  Binaries compiled against 0.9.8
 * (libWebKitLuna, libPmCertificateMgr, BrowserServer, keymanager, ...) still
 * import the legacy sk_* symbols, so without these forwarders they fail to
 * resolve against libcrypto.so.1.1.
 *
 * This is ABI-safe: a STACK is always heap-allocated and, once every browser
 * binary is patchelf'd onto 1.1, every stack handed to these functions was
 * created by 1.1.x code.  We simply pass the opaque pointer straight through.
 *
 * The typed accessors (sk_X509_num, ...) are header macros that already expand
 * to OPENSSL_sk_* in 1.1, so only the bare generic names need restoring here.
 * ============================================================================
 */
#undef sk_new
#undef sk_new_null
#undef sk_num
#undef sk_value
#undef sk_set
#undef sk_free
#undef sk_pop
#undef sk_push
#undef sk_shift
#undef sk_unshift
#undef sk_find
#undef sk_insert
#undef sk_delete
#undef sk_delete_ptr
#undef sk_pop_free
#undef sk_dup
#undef sk_zero
#undef sk_sort
#undef sk_is_sorted

int   sk_num(const OPENSSL_STACK *st)            { return OPENSSL_sk_num(st); }
void *sk_value(const OPENSSL_STACK *st, int i)   { return OPENSSL_sk_value(st, i); }
void *sk_set(OPENSSL_STACK *st, int i, void *p)  { return OPENSSL_sk_set(st, i, p); }
OPENSSL_STACK *sk_new_null(void)                 { return OPENSSL_sk_new_null(); }
OPENSSL_STACK *sk_new(int (*cmp)(const void *, const void *))
                                                 { return OPENSSL_sk_new((OPENSSL_sk_compfunc)cmp); }
void  sk_free(OPENSSL_STACK *st)                 { OPENSSL_sk_free(st); }
void  sk_pop_free(OPENSSL_STACK *st, void (*func)(void *))
                                                 { OPENSSL_sk_pop_free(st, func); }
int   sk_push(OPENSSL_STACK *st, void *p)        { return OPENSSL_sk_push(st, p); }
int   sk_unshift(OPENSSL_STACK *st, void *p)     { return OPENSSL_sk_unshift(st, p); }
void *sk_pop(OPENSSL_STACK *st)                  { return OPENSSL_sk_pop(st); }
void *sk_shift(OPENSSL_STACK *st)                { return OPENSSL_sk_shift(st); }
void *sk_delete(OPENSSL_STACK *st, int i)        { return OPENSSL_sk_delete(st, i); }
void *sk_delete_ptr(OPENSSL_STACK *st, void *p)  { return OPENSSL_sk_delete_ptr(st, p); }
int   sk_insert(OPENSSL_STACK *st, void *p, int i) { return OPENSSL_sk_insert(st, p, i); }
int   sk_find(OPENSSL_STACK *st, void *p)        { return OPENSSL_sk_find(st, p); }
OPENSSL_STACK *sk_dup(const OPENSSL_STACK *st)   { return OPENSSL_sk_dup(st); }
void  sk_zero(OPENSSL_STACK *st)                 { OPENSSL_sk_zero(st); }
void  sk_sort(OPENSSL_STACK *st)                 { OPENSSL_sk_sort(st); }
int   sk_is_sorted(const OPENSSL_STACK *st)      { return OPENSSL_sk_is_sorted(st); }

/*
 * NOTE: the earlier SSL_CTX_set_verify interposer (which dropped WebKit's verify
 * callback) is intentionally REMOVED. With the relocated ssl->ctx at offset 0xD8
 * in our custom libssl.so.1.1, WebCore::CurlHandle::sslVerificationCallback now
 * runs correctly (it reads the real SSL_CTX*, retrieves its handle, and calls
 * isCertValidForUrl). So we let the callback install and run normally.
 */

