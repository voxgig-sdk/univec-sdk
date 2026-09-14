// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/tls.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The TLS binding, and the only file in this port that names OpenSSL.
 *
 * It is under `plugins/` because it is what a plugin is. A chain of the
 * four built-in kinds links no socket, so it links no TLS either, and a
 * consumer that never configures a vault does not carry libssl at all -
 * `make check-core` reads the core archive and says so.
 *
 * The rule this file exists under is AGENTS.md's, stated as a principle
 * rather than a list: cryptographic transport is not hand-rolled. Where a
 * port's standard library has TLS it uses it; where it does not - and C's
 * does not - it binds the platform's audited TLS library, which in C is
 * the one the whole C ecosystem binds. Everything ELSE a standard library
 * lacks is still written in-tree, so the core's json.c, this directory's
 * httpjson.c and sha256.c, and the PEM reader at the foot of this file
 * stay hand-rolled even though libcrypto could do all four. Rust is the
 * worked precedent: `ring` sits inside rustls's closure and
 * rust/src/crypto.rs carries SHA-256 and HMAC anyway.
 *
 * THE AUDIT SURFACE IS `-lssl -lcrypto`, and it is the distribution's
 * OpenSSL: this port pins no version, vendors no source and carries no
 * patch. There is no other edge - `ldd build/sekreto-cli` names libssl,
 * libcrypto and libc, and nothing else.
 *
 * A binding that connects but does not VERIFY is worse than no TLS,
 * because it looks like it works. The four obligations every binding in
 * this repository must meet are met in sek_tls_open below, each marked
 * where it happens:
 *
 *   (1) the chain is verified against the system trust store;
 *   (2) the HOSTNAME is verified - a separate step from (1), and the half
 *       people forget - with the IP-literal case handled separately,
 *       because SSL_set1_host does DNS-name matching and will not match
 *       an iPAddress SAN;
 *   (3) SNI is sent, and NOT for an IP literal, which RFC 6066 forbids;
 *   (4) SEKRETO_CA_BUNDLE adds extra roots, additively.
 */

#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include "support.h"

/* Every certificate in a PEM bundle, as DER. Declared here and defined at
 * the foot of the file: `addbundle` below is its only caller anywhere in
 * the library, so it is a private detail of the TLS binding rather than
 * something the encoders have to carry. */
typedef struct {
  unsigned char **items;
  size_t *lens;
  size_t len;
} sek_ders;

static sek_ders *sek_pemcerts(sek_pool *pool, const char *text);

struct sek_tls_conn {
  SSL_CTX *ctx;
  SSL *ssl;
  sek_pool *pool;
};

int sek_tls_available(void) { return 1; }

/* OpenSSL's own account of what went wrong, which is the only useful text
 * for a rejected certificate: "certificate verify failed" is what a user
 * needs to see, and the errno the syscall layer would report is not. */
static const char *sslreason(sek_pool *pool, SSL *ssl, int code) {
  unsigned long queued = ERR_get_error();
  char buf[256];

  if (0 != queued) {
    ERR_error_string_n(queued, buf, sizeof(buf));
    /* The queue is drained so a later failure cannot report this one. */
    while (0 != ERR_get_error()) {
    }
    return sek_strdup(pool, buf);
  }

  if (NULL != ssl && SSL_ERROR_ZERO_RETURN == SSL_get_error(ssl, code)) {
    return "connection closed";
  }

  return "tls failure";
}

/* Extra trust roots from SEKRETO_CA_BUNDLE - obligation (4).
 *
 * ADDITIVE, never a replacement: the system roots are loaded first and
 * unconditionally, so a private CA is added to them rather than swapped
 * for them. An internal Vault behind a private CA is the common case, not
 * the exotic one, and a port whose bundle variable REPLACED the store
 * would silently stop trusting the public web the moment it was set.
 *
 * FAILS OPEN, SILENTLY: an unreadable file, a file that is not PEM, or a
 * certificate the store rejects is discarded and nothing is raised. A
 * wrong path adds no roots and weakens nothing.
 *
 * The PEM is parsed in-tree (at the foot of this file) rather than
 * through SSL_CTX_load_verify_locations, because the rule keeps PEM on
 * the hand-rolled side of the line even here. */
static void addbundle(sek_pool *pool, SSL_CTX *ctx) {
  const char *path = getenv(SEK_CABUNDLE);
  FILE *file;
  sek_buf text;
  char chunk[4096];
  size_t got;
  sek_ders *ders;
  X509_STORE *store;
  size_t index;

  if (sek_empty(path)) {
    return;
  }

  file = fopen(path, "rb");
  if (NULL == file) {
    return;
  }

  sek_buf_init(&text, pool);
  while (0 < (got = fread(chunk, 1, sizeof(chunk), file))) {
    sek_buf_addn(&text, chunk, got);
  }
  fclose(file);

  ders = sek_pemcerts(pool, text.data);
  store = SSL_CTX_get_cert_store(ctx);

  if (NULL == store) {
    return;
  }

  for (index = 0; index < ders->len; index++) {
    const unsigned char *at = ders->items[index];
    X509 *cert = d2i_X509(NULL, &at, (long)ders->lens[index]);

    if (NULL == cert) {
      continue;
    }

    /* A duplicate or otherwise unacceptable certificate is discarded. */
    X509_STORE_add_cert(store, cert);
    X509_free(cert);
  }

  /* Anything OpenSSL queued while rejecting a certificate is dropped, so
   * a later handshake failure does not report this instead of itself. */
  while (0 != ERR_get_error()) {
  }
}

static int isipliteral(const char *host) {
  unsigned char scratch[16];

  return 1 == inet_pton(AF_INET, host, scratch) || 1 == inet_pton(AF_INET6, host, scratch);
}

sek_err sek_tls_open(sek_pool *pool, int fd, const char *host, sek_tls_conn **out) {
  sek_tls_conn *conn = (sek_tls_conn *)sek_alloc(pool, sizeof(sek_tls_conn));
  X509_VERIFY_PARAM *param;
  int shook;
  int literal = isipliteral(host);

  conn->pool = pool;
  conn->ctx = SSL_CTX_new(TLS_client_method());

  if (NULL == conn->ctx) {
    return sek_fmt(pool, "tls setup failed: %s", sslreason(pool, NULL, 0));
  }

  /* (1) THE CHAIN, against the system trust store.
   *
   * set_default_verify_paths loads the distribution's CA directory, and
   * honours SSL_CERT_FILE / SSL_CERT_DIR while doing it. set_verify with
   * SSL_VERIFY_PEER and a NULL callback is what makes a verification
   * failure ABORT the handshake - without it OpenSSL happily completes
   * one against a certificate it does not trust and leaves the verdict
   * for a caller to remember to ask about. */
  if (1 != SSL_CTX_set_default_verify_paths(conn->ctx)) {
    SSL_CTX_free(conn->ctx);
    return sek_fmt(pool, "tls setup failed: no system trust store");
  }
  SSL_CTX_set_verify(conn->ctx, SSL_VERIFY_PEER, NULL);

  /* Nothing below TLS 1.2. */
  SSL_CTX_set_min_proto_version(conn->ctx, TLS1_2_VERSION);

  /* (4) extra roots, additive. */
  addbundle(pool, conn->ctx);

  conn->ssl = SSL_new(conn->ctx);
  if (NULL == conn->ssl) {
    SSL_CTX_free(conn->ctx);
    return sek_fmt(pool, "tls setup failed: %s", sslreason(pool, NULL, 0));
  }

  param = SSL_get0_param(conn->ssl);
  X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

  /* (2) THE HOSTNAME. Separate from (1): a valid certificate for some
   * other host chains perfectly well.
   *
   * The two cases are genuinely different checks. SSL_set1_host matches
   * DNS names against dNSName SANs, and will NOT match an iPAddress SAN -
   * so an IP literal has to go through set1_ip_asc instead. This
   * repository's own TLS endpoint is https://127.0.0.1:8304, so a port
   * that treats every host as a name fails there, and a port that only
   * ever tested against that endpoint could ship with no name check at
   * all. Both are set here, and both before the handshake. */
  if (literal) {
    if (1 != X509_VERIFY_PARAM_set1_ip_asc(param, host)) {
      SSL_free(conn->ssl);
      SSL_CTX_free(conn->ctx);
      return sek_fmt(pool, "tls setup failed: bad address %s", host);
    }
  } else {
    if (1 != SSL_set1_host(conn->ssl, host)) {
      SSL_free(conn->ssl);
      SSL_CTX_free(conn->ctx);
      return sek_fmt(pool, "tls setup failed: bad host name %s", host);
    }

    /* (3) SNI, for a name only. RFC 6066 forbids a literal address in
     * server_name, and OpenSSL will send whatever it is handed. */
    SSL_set_tlsext_host_name(conn->ssl, host);
  }

  SSL_set_fd(conn->ssl, fd);

  shook = SSL_connect(conn->ssl);
  if (1 != shook) {
    sek_err why = sek_fmt(pool, "%s", sslreason(pool, conn->ssl, shook));
    SSL_free(conn->ssl);
    SSL_CTX_free(conn->ctx);
    return why;
  }

  /* Belt and braces. SSL_VERIFY_PEER above already aborts on a bad chain,
   * but a future edit that weakened it would be silent, and these two
   * lines are not. A peer that presented no certificate at all is caught
   * here whatever the verify mode says. */
  if (X509_V_OK != SSL_get_verify_result(conn->ssl)) {
    sek_err why = sek_fmt(pool, "certificate verify failed: %s",
                          X509_verify_cert_error_string(SSL_get_verify_result(conn->ssl)));
    SSL_free(conn->ssl);
    SSL_CTX_free(conn->ctx);
    return why;
  }

  {
    X509 *peer = SSL_get1_peer_certificate(conn->ssl);
    if (NULL == peer) {
      SSL_free(conn->ssl);
      SSL_CTX_free(conn->ctx);
      return sek_strdup(pool, "server presented no certificate");
    }
    X509_free(peer);
  }

  *out = conn;

  return NULL;
}

long sek_tls_write(sek_tls_conn *conn, const char *data, size_t len, sek_err *err) {
  int wrote = SSL_write(conn->ssl, data, (int)len);

  if (0 >= wrote) {
    *err = sslreason(conn->pool, conn->ssl, wrote);
    return -1;
  }

  return wrote;
}

long sek_tls_read(sek_tls_conn *conn, char *data, size_t len, sek_err *err) {
  int got = SSL_read(conn->ssl, data, (int)len);

  if (0 < got) {
    return got;
  }

  {
    int why = SSL_get_error(conn->ssl, got);

    /* A clean close_notify is the end of the body. */
    if (SSL_ERROR_ZERO_RETURN == why) {
      return 0;
    }

    /* SSL_ERROR_SYSCALL is two different things and they must not be
     * collapsed. errno 0 means the peer closed WITHOUT close_notify,
     * which is the ordinary end of a `Connection: close` exchange -
     * refusing it would turn every such response into an unreachable
     * store. EAGAIN means the socket's own deadline fired: the body is
     * TRUNCATED, and reporting that as end-of-stream would hand a half
     * response to the parser and call whatever it made of it an answer. */
    /* OpenSSL 3.0 reports a peer that closed without close_notify as
     * SSL_ERROR_SSL with this reason rather than as SSL_ERROR_SYSCALL.
     * It is the same ordinary end of a `Connection: close` exchange, so
     * it is read the same way - and the HTTP framing above still decides
     * whether what arrived is a whole response. */
    if (SSL_ERROR_SSL == why &&
        SSL_R_UNEXPECTED_EOF_WHILE_READING == ERR_GET_REASON(ERR_peek_error())) {
      while (0 != ERR_get_error()) {
      }
      return 0;
    }

    if (SSL_ERROR_SYSCALL == why) {
      if (EAGAIN == errno || EWOULDBLOCK == errno) {
        *err = "timed out";
        return -1;
      }
      if (0 == errno) {
        return 0;
      }
      *err = strerror(errno);
      return -1;
    }
  }

  *err = sslreason(conn->pool, conn->ssl, got);

  return -1;
}

void sek_tls_close(sek_tls_conn *conn) {
  if (NULL == conn) {
    return;
  }

  if (NULL != conn->ssl) {
    SSL_shutdown(conn->ssl);
    SSL_free(conn->ssl);
    conn->ssl = NULL;
  }

  if (NULL != conn->ctx) {
    SSL_CTX_free(conn->ctx);
    conn->ctx = NULL;
  }
}

/* ---- PEM ----------------------------------------------------------- */


/* The trust-anchor reader, HERE rather than beside the base64 it uses,
 * because tls.c is its only caller and an object nothing else pulls is an
 * object no other plugin has to carry.
 *
 * Certificates only: no header handling, no other label, no private keys.
 * Trust anchors are all this port ever parses out of a PEM file. */
static sek_ders *sek_pemcerts(sek_pool *pool, const char *text) {
  static const char OPEN[] = "-----BEGIN CERTIFICATE-----";
  static const char CLOSE[] = "-----END CERTIFICATE-----";

  sek_ders *out = (sek_ders *)sek_alloc(pool, sizeof(sek_ders));
  size_t cap = 8;
  const char *rest = text;

  out->items = (unsigned char **)sek_alloc(pool, cap * sizeof(unsigned char *));
  out->lens = (size_t *)sek_alloc(pool, cap * sizeof(size_t));
  out->len = 0;

  while (NULL != rest) {
    const char *start = strstr(rest, OPEN);
    const char *body;
    const char *end;
    char *span;
    size_t derlen = 0;
    unsigned char *der;

    if (NULL == start) {
      break;
    }

    body = start + sizeof(OPEN) - 1;
    end = strstr(body, CLOSE);
    if (NULL == end) {
      break;
    }

    span = sek_strndup(pool, body, (size_t)(end - body));
    der = sek_unbase64(pool, span, &derlen);

    if (NULL != der && 0 < derlen) {
      if (out->len == cap) {
        size_t bigger = cap * 2;
        unsigned char **items =
            (unsigned char **)sek_alloc(pool, bigger * sizeof(unsigned char *));
        size_t *lens = (size_t *)sek_alloc(pool, bigger * sizeof(size_t));
        memcpy(items, out->items, out->len * sizeof(unsigned char *));
        memcpy(lens, out->lens, out->len * sizeof(size_t));
        out->items = items;
        out->lens = lens;
        cap = bigger;
      }
      out->items[out->len] = der;
      out->lens[out->len] = derlen;
      out->len++;
    }

    rest = end + sizeof(CLOSE) - 1;
  }

  return out;
}
