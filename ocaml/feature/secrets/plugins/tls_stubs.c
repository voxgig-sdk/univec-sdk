(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/tls_stubs.c) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
/* The TLS binding: OpenSSL, and nothing else from it.
 *
 * OCaml's distribution has Unix sockets but no TLS, and TLS is the one
 * thing this repository has decided must not be hand-rolled. So this file
 * binds the platform's audited TLS library - libssl and libcrypto - which
 * is what ocaml-ssl, conduit and every other OCaml program that speaks
 * https ultimately bind too. It is the WHOLE of the port's third-party
 * surface, and it is confined to this one file plus its thin OCaml wrapper.
 *
 * The audit surface is the dependency closure, not the direct edge: `-lssl
 * -lcrypto`, and the distribution's OpenSSL is that surface.
 *
 * Nothing else here comes from OpenSSL. HTTP framing, JSON, base64,
 * SHA-256 and HMAC are all in-tree - calling libcrypto's EVP_Digest for
 * SigV4 would widen "cryptographic transport is not hand-rolled" into
 * "cryptography is not hand-rolled", which is not the rule.
 *
 * Four obligations, all of them met below and none of them optional. A
 * binding that connects without verifying is worse than no TLS, because it
 * looks like it works.
 *
 *   1. the chain is verified against the system trust store -
 *      SSL_CTX_set_default_verify_paths plus SSL_VERIFY_PEER with a NULL
 *      callback, so a verification error aborts the handshake; belt and
 *      braces, SSL_get_verify_result and the presence of a peer
 *      certificate are checked afterwards as well.
 *   2. the HOSTNAME is verified, which is a separate step from the chain
 *      and is the half that gets forgotten - SSL_set1_host for a DNS name,
 *      X509_VERIFY_PARAM_set1_ip_asc for an IP literal, because
 *      SSL_set1_host does DNS-name matching and will not match an
 *      iPAddress SAN.
 *   3. SNI is sent - SSL_set_tlsext_host_name - and NOT for an IP literal,
 *      which RFC 6066 forbids and which OpenSSL will happily send anyway.
 *   4. SEKRETO_CA_BUNDLE adds roots, additively and never as a
 *      replacement, and fails open in silence: a wrong path adds no roots
 *      and raises nothing.
 *
 * TLS 1.2 is the floor. Renegotiation, session tickets and client
 * certificates are not used.
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/custom.h>

#include <string.h>
#include <stdlib.h>
#include <errno.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

struct sekconn {
  SSL_CTX *ctx;
  SSL *ssl;
};

#define Conn_val(v) (*((struct sekconn **) Data_custom_val(v)))

static void sekreto_conn_free(struct sekconn *conn)
{
  if (NULL == conn) {
    return;
  }
  if (NULL != conn->ssl) {
    SSL_free(conn->ssl);
    conn->ssl = NULL;
  }
  if (NULL != conn->ctx) {
    SSL_CTX_free(conn->ctx);
    conn->ctx = NULL;
  }
  free(conn);
}

static void sekreto_conn_finalize(value v)
{
  sekreto_conn_free(Conn_val(v));
  Conn_val(v) = NULL;
}

static struct custom_operations sekreto_conn_ops = {
  "org.voxgig.sekreto.tls",
  sekreto_conn_finalize,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

/* The last OpenSSL error as text, or a stand-in. The queue is drained
 * either way, so a later handshake cannot report an earlier failure. */
static void sekreto_why(char *out, size_t len, const char *fallback)
{
  unsigned long code = ERR_get_error();

  if (0 == code) {
    snprintf(out, len, "%s", fallback);
  } else {
    char buf[256];
    ERR_error_string_n(code, buf, sizeof(buf));
    snprintf(out, len, "%s", buf);
  }

  ERR_clear_error();
}

/* Open a TLS connection over an already-connected socket.
 *
 *   fd        the connected socket, which stays owned by OCaml
 *   host      the bare host: no brackets, no port, no userinfo
 *   isip      whether `host` is an IP literal rather than a DNS name
 *   cabundle  SEKRETO_CA_BUNDLE, or the empty string
 */
CAMLprim value sekreto_tls_connect(value vfd, value vhost, value visip, value vca)
{
  CAMLparam4(vfd, vhost, visip, vca);
  CAMLlocal1(result);

  char why[512];
  const char *host = String_val(vhost);
  const char *ca = String_val(vca);
  int isip = Bool_val(visip);
  int fd = Int_val(vfd);

  struct sekconn *conn = (struct sekconn *) calloc(1, sizeof(struct sekconn));
  if (NULL == conn) {
    caml_failwith("out of memory");
  }

  ERR_clear_error();

  conn->ctx = SSL_CTX_new(TLS_client_method());
  if (NULL == conn->ctx) {
    sekreto_why(why, sizeof(why), "cannot create a TLS context");
    sekreto_conn_free(conn);
    caml_failwith(why);
  }

  /* (1) Chain verification, twice over: the trust store is loaded, and the
   * NULL callback means a verification failure aborts the handshake rather
   * than being reported and ignored. set_default_verify_paths also honours
   * SSL_CERT_FILE and SSL_CERT_DIR, which is how OpenSSL programs are
   * normally pointed at a different store. */
  SSL_CTX_set_verify(conn->ctx, SSL_VERIFY_PEER, NULL);

  if (1 != SSL_CTX_set_min_proto_version(conn->ctx, TLS1_2_VERSION)) {
    sekreto_why(why, sizeof(why), "cannot require TLS 1.2");
    sekreto_conn_free(conn);
    caml_failwith(why);
  }

  if (1 != SSL_CTX_set_default_verify_paths(conn->ctx)) {
    sekreto_why(why, sizeof(why), "no system trust store");
    sekreto_conn_free(conn);
    caml_failwith(why);
  }

  /* (4) SEKRETO_CA_BUNDLE, additive and failing open. The default roots
   * are already loaded above and stay loaded whatever this does; an
   * unreadable file or a certificate OpenSSL rejects simply adds nothing.
   * A wrong path must not weaken the store and must not raise. */
  if ('\0' != ca[0]) {
    if (1 != SSL_CTX_load_verify_locations(conn->ctx, ca, NULL)) {
      ERR_clear_error();
    }
  }

  conn->ssl = SSL_new(conn->ctx);
  if (NULL == conn->ssl) {
    sekreto_why(why, sizeof(why), "cannot create a TLS session");
    sekreto_conn_free(conn);
    caml_failwith(why);
  }

  {
    /* (2) Hostname verification - separate from the chain, and the half
     * people forget. An IP literal needs the iPAddress form: SSL_set1_host
     * does DNS-name matching and never matches an iPAddress SAN, and this
     * repository's only TLS test endpoint is an IP literal. */
    X509_VERIFY_PARAM *param = SSL_get0_param(conn->ssl);

    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

    if (isip) {
      if (1 != X509_VERIFY_PARAM_set1_ip_asc(param, host)) {
        sekreto_why(why, sizeof(why), "cannot verify that address");
        sekreto_conn_free(conn);
        caml_failwith(why);
      }
    } else {
      if (1 != SSL_set1_host(conn->ssl, host)) {
        sekreto_why(why, sizeof(why), "cannot verify that host name");
        sekreto_conn_free(conn);
        caml_failwith(why);
      }

      /* (3) SNI, for a name only: RFC 6066 forbids a literal address here,
       * and OpenSSL sends whatever it is handed. */
      if (1 != SSL_set_tlsext_host_name(conn->ssl, host)) {
        sekreto_why(why, sizeof(why), "cannot send SNI");
        sekreto_conn_free(conn);
        caml_failwith(why);
      }
    }
  }

  if (1 != SSL_set_fd(conn->ssl, fd)) {
    sekreto_why(why, sizeof(why), "cannot attach the socket");
    sekreto_conn_free(conn);
    caml_failwith(why);
  }

  if (1 != SSL_connect(conn->ssl)) {
    long verified = SSL_get_verify_result(conn->ssl);

    if (X509_V_OK != verified) {
      snprintf(why, sizeof(why), "certificate verify failed: %s",
               X509_verify_cert_error_string(verified));
      ERR_clear_error();
    } else {
      sekreto_why(why, sizeof(why), "handshake failed");
    }

    sekreto_conn_free(conn);
    caml_failwith(why);
  }

  /* Belt and braces. SSL_VERIFY_PEER already aborts on a bad chain, but a
   * handshake that somehow completed without a verified peer certificate
   * must not be used to carry a token. */
  {
    long verified = SSL_get_verify_result(conn->ssl);
    X509 *peer = SSL_get1_peer_certificate(conn->ssl);

    if (NULL == peer) {
      sekreto_conn_free(conn);
      caml_failwith("the server sent no certificate");
    }

    X509_free(peer);

    if (X509_V_OK != verified) {
      snprintf(why, sizeof(why), "certificate verify failed: %s",
               X509_verify_cert_error_string(verified));
      sekreto_conn_free(conn);
      caml_failwith(why);
    }
  }

  result = caml_alloc_custom(&sekreto_conn_ops, sizeof(struct sekconn *), 0, 1);
  Conn_val(result) = conn;

  CAMLreturn(result);
}

/* Write, answering how many bytes went out. */
CAMLprim value sekreto_tls_write(value vconn, value vbuf, value vofs, value vlen)
{
  CAMLparam4(vconn, vbuf, vofs, vlen);

  struct sekconn *conn = Conn_val(vconn);
  char why[512];
  int wrote;

  if (NULL == conn) {
    caml_failwith("the connection is closed");
  }

  ERR_clear_error();
  wrote = SSL_write(conn->ssl, String_val(vbuf) + Long_val(vofs), (int) Long_val(vlen));

  if (0 >= wrote) {
    int reason = SSL_get_error(conn->ssl, wrote);

    if (SSL_ERROR_WANT_READ == reason || SSL_ERROR_WANT_WRITE == reason) {
      caml_failwith("timed out");
    }

    sekreto_why(why, sizeof(why), "connection lost while writing");
    caml_failwith(why);
  }

  CAMLreturn(Val_long(wrote));
}

/* Read, answering how many bytes arrived; 0 means the peer is done.
 *
 * The runtime lock is not released, so the GC cannot run and cannot move
 * the destination while OpenSSL writes into it. */
CAMLprim value sekreto_tls_read(value vconn, value vbuf, value vofs, value vlen)
{
  CAMLparam4(vconn, vbuf, vofs, vlen);

  struct sekconn *conn = Conn_val(vconn);
  char why[512];
  int got;

  if (NULL == conn) {
    caml_failwith("the connection is closed");
  }

  ERR_clear_error();
  got = SSL_read(conn->ssl, Bytes_val(vbuf) + Long_val(vofs), (int) Long_val(vlen));

  if (0 >= got) {
    int reason = SSL_get_error(conn->ssl, got);

    /* A clean close_notify, and a peer that simply closed the socket after
     * a complete response, both mean the body has ended. */
    if (SSL_ERROR_ZERO_RETURN == reason) {
      CAMLreturn(Val_long(0));
    }

    if (SSL_ERROR_SYSCALL == reason && 0 == ERR_peek_error()) {
      if (EAGAIN == errno || EWOULDBLOCK == errno) {
        caml_failwith("timed out");
      }
      CAMLreturn(Val_long(0));
    }

    if (SSL_ERROR_WANT_READ == reason || SSL_ERROR_WANT_WRITE == reason) {
      caml_failwith("timed out");
    }

    sekreto_why(why, sizeof(why), "connection lost while reading");
    caml_failwith(why);
  }

  CAMLreturn(Val_long(got));
}

CAMLprim value sekreto_tls_close(value vconn)
{
  CAMLparam1(vconn);

  struct sekconn *conn = Conn_val(vconn);

  if (NULL != conn) {
    if (NULL != conn->ssl) {
      SSL_shutdown(conn->ssl);
    }
    sekreto_conn_free(conn);
    Conn_val(vconn) = NULL;
  }

  ERR_clear_error();

  CAMLreturn(Val_unit);
}
