/*
 * The libcurl binding behind `@[extern "sekreto_curl_fetch"]` in the
 * vendored SekretoPlugins.Httpjson (src/feature/secrets/sekreto/plugins/).
 *
 * WHY THIS FILE IS SDKGEN'S AND NOT VENDORED. Upstream sekreto keeps the
 * same binding at lean/ffi/sekreto_curl.c, and this is a re-statement of its
 * contract rather than a copy of its text: the vendoring tool stamps and the
 * vendoring guard checks a provenance header in the TEMPLATE LANGUAGE's
 * comment syntax (`--` for everything under tm/lean/), and a C file cannot
 * open with `--`. So the two stubs under ffi/ are ordinary template source,
 * written against the contract the Lean side documents, and a resync of
 * sekreto must be checked against that contract by hand (framing, the
 * argument list, and the four TLS obligations below).
 *
 * The contract, as SekretoPlugins.Httpjson states it:
 *
 *   curlfetch method url headers body hasbody cabundle : IO ByteArray
 *
 * every String BORROWED (`@&`), `headers` one `Name: value` per line, and
 * the answer framed so that nothing about it can be mistaken for a body:
 *
 *   byte 0      'O' answered | 'E' could not reach | 'Z' oversized
 *   bytes 1..4  the HTTP status, big-endian ('O' only, else zero)
 *   bytes 5..   the body bytes ('O') or the failure text ('E')
 *
 * The obligations every sekreto transport binding meets:
 *
 *   1. verify the chain against the system trust store
 *      (CURLOPT_SSL_VERIFYPEER = 1; CURLOPT_CAINFO is never set, so the
 *      default store stays in force)
 *   2. verify the HOSTNAME, separately (CURLOPT_SSL_VERIFYHOST = 2)
 *   3. send SNI (libcurl does, for a DNS name; correctly not for an IP)
 *   4. honour SEKRETO_CA_BUNDLE as EXTRA roots, additively
 *      (CURLOPT_SSL_CTX_FUNCTION + SSL_CTX_load_verify_locations on the
 *      context libcurl already filled with the system roots - which is
 *      the one call `-lssl -lcrypto` are linked for, and works on the
 *      OpenSSL backend only, failing OPEN elsewhere as documented)
 *
 * plus: no redirects, no proxies, http/https only, HTTP/1.1, TLS 1.2 or
 * better, a ten-second bound on the round-trip, an eight-mebibyte body cap.
 *
 * Compiled by the system C compiler against the toolchain's <lean/lean.h>
 * (`make ffi`); the object is named in lakefile.toml's moreLinkArgs. Both
 * happen only when the model selects a plugin group.
 */

#include <lean/lean.h>

#include <stdlib.h>
#include <string.h>

#include <curl/curl.h>
#include <openssl/ssl.h>

#define SEKRETO_MAXBODY (8 * 1024 * 1024)

typedef struct {
  char *data;
  size_t size;
  int over;
} sekreto_buf;

/* Accumulate the body; refuse (short write -> CURLE_WRITE_ERROR) past the
 * cap, and remember that it was the cap and not the network. */
static size_t sekreto_write(char *chunk, size_t width, size_t count, void *into) {
  sekreto_buf *buf = (sekreto_buf *)into;
  size_t add = width * count;

  if (buf->size + add > (size_t)SEKRETO_MAXBODY) {
    buf->over = 1;
    return 0;
  }

  char *grown = (char *)realloc(buf->data, buf->size + add + 1);
  if (NULL == grown) {
    return 0;
  }

  buf->data = grown;
  memcpy(buf->data + buf->size, chunk, add);
  buf->size += add;
  buf->data[buf->size] = '\0';
  return add;
}

/* Obligation 4: extra roots IN ADDITION to the system store. An unreadable
 * or unusable bundle adds nothing and raises nothing (fail-open, as every
 * sekreto port documents for this variable). */
static CURLcode sekreto_sslctx(CURL *handle, void *sslctx, void *given) {
  const char *bundle = (const char *)given;
  (void)handle;

  if (NULL != bundle && '\0' != bundle[0]) {
    (void)SSL_CTX_load_verify_locations((SSL_CTX *)sslctx, bundle, NULL);
  }
  return CURLE_OK;
}

static lean_obj_res sekreto_frame(char tag, unsigned status, const char *payload,
                                  size_t size) {
  lean_object *out = lean_alloc_sarray(1, size + 5, size + 5);
  uint8_t *at = lean_sarray_cptr(out);

  at[0] = (uint8_t)tag;
  at[1] = (uint8_t)((status >> 24) & 0xff);
  at[2] = (uint8_t)((status >> 16) & 0xff);
  at[3] = (uint8_t)((status >> 8) & 0xff);
  at[4] = (uint8_t)(status & 0xff);

  if (0 != size && NULL != payload) {
    memcpy(at + 5, payload, size);
  }
  return out;
}

/* Split the newline-framed header block into a curl_slist, in place on a
 * private copy. Empty lines are skipped. */
static struct curl_slist *sekreto_headers(const char *framed, char **keep) {
  struct curl_slist *list = NULL;
  size_t len = strlen(framed);
  char *lines = (char *)malloc(len + 1);

  *keep = lines;
  if (NULL == lines) {
    return NULL;
  }
  memcpy(lines, framed, len + 1);

  char *at = lines;
  while ('\0' != *at) {
    char *stop = strchr(at, '\n');
    if (NULL != stop) {
      *stop = '\0';
    }
    if ('\0' != *at) {
      list = curl_slist_append(list, at);
    }
    if (NULL == stop) {
      break;
    }
    at = stop + 1;
  }
  return list;
}

LEAN_EXPORT lean_obj_res sekreto_curl_fetch(b_lean_obj_arg method, b_lean_obj_arg url,
                                            b_lean_obj_arg headers, b_lean_obj_arg body,
                                            uint8_t hasbody, b_lean_obj_arg cabundle,
                                            lean_obj_arg world) {
  (void)world;

  static int started = 0;
  if (0 == started) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    started = 1;
  }

  CURL *handle = curl_easy_init();
  if (NULL == handle) {
    return lean_io_result_mk_ok(sekreto_frame('E', 0, "no curl handle", 14));
  }

  sekreto_buf buf = {NULL, 0, 0};
  char *keep = NULL;
  struct curl_slist *list = sekreto_headers(lean_string_cstr(headers), &keep);
  /* Drop libcurl's own `Expect: 100-continue`, which several vault APIs
   * answer badly. */
  list = curl_slist_append(list, "Expect:");

  curl_easy_setopt(handle, CURLOPT_URL, lean_string_cstr(url));
  curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, lean_string_cstr(method));
  curl_easy_setopt(handle, CURLOPT_HTTPHEADER, list);
  curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, sekreto_write);
  curl_easy_setopt(handle, CURLOPT_WRITEDATA, (void *)&buf);

  /* Obligations 1 and 2, and the floor on the protocol version. */
  curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(handle, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(handle, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);

  /* Obligation 4. */
  const char *bundle = lean_string_cstr(cabundle);
  if ('\0' != bundle[0]) {
    curl_easy_setopt(handle, CURLOPT_SSL_CTX_FUNCTION, sekreto_sslctx);
    curl_easy_setopt(handle, CURLOPT_SSL_CTX_DATA, (void *)bundle);
  }

  /* A followed redirect would carry a vault token to a host the address
   * check never saw; a proxy from the environment has leaked one before. */
  curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(handle, CURLOPT_PROXY, "");
  curl_easy_setopt(handle, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
  curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, 10000L);
  curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
  curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(handle, CURLOPT_ACCEPT_ENCODING, "");

  if (0 != hasbody) {
    curl_easy_setopt(handle, CURLOPT_POSTFIELDS, lean_string_cstr(body));
    curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, (long)lean_string_size(body) - 1);
  }

  CURLcode outcome = curl_easy_perform(handle);

  long status = 0;
  curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);

  lean_obj_res answer;
  if (CURLE_OK == outcome) {
    answer = sekreto_frame('O', (unsigned)status, buf.data, buf.size);
  } else if (0 != buf.over) {
    answer = sekreto_frame('Z', 0, "", 0);
  } else {
    const char *why = curl_easy_strerror(outcome);
    answer = sekreto_frame('E', 0, why, strlen(why));
  }

  curl_slist_free_all(list);
  free(keep);
  free(buf.data);
  curl_easy_cleanup(handle);

  return lean_io_result_mk_ok(answer);
}
