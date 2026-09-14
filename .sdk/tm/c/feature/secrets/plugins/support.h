// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/support.h)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* What the PLUGINS share and the core must never link: the HTTP
 * transport, the TLS seam, the SHA-256 primitives SigV4 is built from,
 * the two encoders, a child process and a clock.
 *
 * ONE TRANSLATION UNIT PER CAPABILITY, and that is a link-time decision
 * rather than a filing preference. A static archive is pulled in an
 * object at a time, so a plugin that signs nothing must not sit in the
 * same object as the signer, and the shared percent-encoder must not
 * either - `sek_uriescape` is used by four stores that hash nothing, so
 * it lives with the transport in `encode.c` and SigV4 depends on it,
 * never the other way round. `make check-core` reads the link and says
 * which objects each plugin actually pulls.
 *
 * The core's own header, `src/internal.h`, is the other half of what a
 * plugin compiles against; nothing here is visible from `src/`.
 */

#ifndef VOXGIG_SEKRETO_PLUGIN_SUPPORT_H
#define VOXGIG_SEKRETO_PLUGIN_SUPPORT_H

#include <stddef.h>

#include "internal.h"
#include "sekretoplugins.h"

/* ---- crypto -------------------------------------------------------- */

/* FIPS 180-4 SHA-256 and RFC 2104 HMAC-SHA256, hand-rolled.
 *
 * Hand-rolled even though this port links libcrypto, and that is the
 * rule, not an oversight: the TLS exception covers cryptographic
 * TRANSPORT and nothing else. Rust is the worked precedent - `ring` is
 * already inside rustls's dependency closure and rust/src/crypto.rs still
 * carries both primitives. Both are proved by the SigV4 known-answer
 * vectors: a signature is a chain of these, so one wrong bit fails there.
 *
 * `sha256.c` and nothing else. The aws plugin is the only thing in the
 * library that names these, and a link of any other plugin must not pull
 * the object they are in. */
#define SEK_SHA256_LEN 32

void sek_sha256(const unsigned char *data, size_t len, unsigned char out[SEK_SHA256_LEN]);
void sek_hmac_sha256(const unsigned char *key, size_t keylen, const unsigned char *data,
                     size_t datalen, unsigned char out[SEK_SHA256_LEN]);

char *sek_hex(sek_pool *pool, const unsigned char *bytes, size_t len);
char *sek_sha256hex(sek_pool *pool, const char *text);

/* ---- encoders ------------------------------------------------------ */

/* Strict standard base64. Answers NULL for anything outside the alphabet,
 * for a length that is not a multiple of four, or for more than two
 * padding characters. A lenient decoder hands back plausible bytes for a
 * corrupted payload, and those bytes are then returned AS THE SECRET.
 *
 * With `sek_uriescape` in `encode.c`, not with the signer: base64 decodes
 * an AWS binary secret and a GCP payload, percent-encoding builds four
 * stores' URLs, and none of those five hashes anything. */
unsigned char *sek_unbase64(sek_pool *pool, const char *text, size_t *outlen);

/* ---- http ---------------------------------------------------------- */

/* How long any single vault round-trip may take before it is treated as
 * unreachable, and how much of a body will be read before the store is
 * treated as having answered incoherently. Ports carry the same bounds. */
#define SEK_TIMEOUT_MS 10000
#define SEK_MAXBODY (8 * 1024 * 1024)

typedef struct {
  int status;
  char *body;
  size_t bodylen;
} sek_response;

/* One HTTP exchange. A non-2xx status is returned, not raised: a 404 from
 * a vault means "no such secret", which is a miss rather than a failure. */
sek_err sek_http(sek_pool *pool, const char *method, const char *url, const sek_map *headers,
                 const char *body, sek_response *out);

/* One JSON round-trip: status plus parsed body. A 200 whose body does not
 * parse is an error - the store answered incoherently, and reading that
 * as a miss would fall through to a weaker store. */
typedef struct {
  int status;
  sek_json *body;
} sek_answer;

sek_err sek_fetchjson(sek_pool *pool, const char *method, const char *url, const sek_map *headers,
                      const char *body, sek_answer *out);

/* ---- tls ----------------------------------------------------------- */

/* The whole TLS surface of this port. `sek_tls_conn` is opaque: nothing
 * outside tls.c knows it is an OpenSSL SSL*.
 *
 * The four obligations every binding in this repository must meet are
 * met inside sek_tls_open, and are stated on its definition: chain
 * verification against the system trust store, HOSTNAME verification
 * (separate from chain verification, and the half people forget), SNI,
 * and additive extra roots from SEKRETO_CA_BUNDLE. */
typedef struct sek_tls_conn sek_tls_conn;

/* The variable naming extra trust roots, as a PEM bundle. Additive: the
 * system roots are loaded first, unconditionally. */
#define SEK_CABUNDLE "SEKRETO_CA_BUNDLE"

/* Wrap a connected socket in TLS for `host`. `host` is the bare host with
 * any IPv6 brackets stripped - it is both the SNI name and the identity
 * the certificate is checked against. Returns an error message on any
 * failure, including a rejected certificate. */
sek_err sek_tls_open(sek_pool *pool, int fd, const char *host, sek_tls_conn **out);

/* Read and write with the same deadline discipline as the plain socket.
 * Both answer < 0 on error and set *err; a read of 0 is end of stream. */
long sek_tls_write(sek_tls_conn *conn, const char *data, size_t len, sek_err *err);
long sek_tls_read(sek_tls_conn *conn, char *data, size_t len, sek_err *err);
void sek_tls_close(sek_tls_conn *conn);

/* Is this build able to speak TLS at all? Zero means every https address
 * must be refused loudly rather than reached quietly. */
int sek_tls_available(void);

/* ---- subprocess ---------------------------------------------------- */

typedef struct {
  char *out;
  char *why; /* stderr, trimmed */
  int status;
} sek_ran;

/* Run a child to completion and collect both its streams. Only `boru` and
 * `secretspec` reach this, and it is the only object in the library that
 * forks. */
sek_err sek_runcmd(sek_pool *pool, char *const argv[], const char *command, const char *envkey,
                   const char *envval, sek_ran *out);

/* ---- clock --------------------------------------------------------- */

/* When a logged-in token must be renewed, from its expiry in seconds (a
 * JSON number, or a string as Azure IMDS sends it). A missing or zero
 * expiry means never - which is what a configured token gets. */
#define SEK_NEVER 0x7fffffffffffffffll

long long sek_renewtime(const sek_json *expires);
long long sek_nowms(void);

/* The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. */
char *sek_awsnow(sek_pool *pool);

#endif /* VOXGIG_SEKRETO_PLUGIN_SUPPORT_H */
