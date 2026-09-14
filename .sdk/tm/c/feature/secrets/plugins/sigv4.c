// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/sigv4.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* AWS Signature Version 4, hand-rolled.
 *
 * The AWS providers need exactly one thing from the AWS SDK - request
 * signing - and there is no SDK to take in C anyway. SigV4 is a stable,
 * published algorithm built from HMAC-SHA256, which `sha256.c` carries.
 *
 * IT MOVED HERE WITH THE AWS PLUGIN, and the core of no port imports a
 * hash function any more. Only this file and `sha256.c` name a digest;
 * the percent-encoder it needs is in `encode.c` with the transport, so
 * that a store which builds URLs but signs nothing never pulls SHA-256
 * into its link.
 *
 * `sek_sigv4` is pure: the caller passes the timestamp, so the same input
 * yields the same signature everywhere. That is what lets the shared spec
 * carry known-answer cases every port must reproduce bit for bit, and
 * lets the integration mock recompute the signature server-side.
 *
 * A port of typescript/src/Sigv4.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <string.h>

#include "support.h"

static int hexval(char ch) {
  if ('0' <= ch && '9' >= ch) {
    return ch - '0';
  }
  if ('a' <= ch && 'f' >= ch) {
    return ch - 'a' + 10;
  }
  if ('A' <= ch && 'F' >= ch) {
    return ch - 'A' + 10;
  }
  return -1;
}

/* Percent-decode, and nothing else: `+` stays `+`, as it is on the wire,
 * and a malformed escape is kept literal. */
static char *uridecode(sek_pool *pool, const char *text) {
  sek_buf out;
  size_t index = 0;
  size_t len = strlen(text);

  sek_buf_init(&out, pool);

  while (index < len) {
    if ('%' == text[index] && index + 2 < len) {
      int hi = hexval(text[index + 1]);
      int lo = hexval(text[index + 2]);
      if (0 <= hi && 0 <= lo) {
        sek_buf_addch(&out, (char)((hi << 4) | lo));
        index += 3;
        continue;
      }
    }

    sek_buf_addch(&out, text[index]);
    index++;
  }

  return out.data;
}

/* The canonical query string: each pair decoded then re-escaped, sorted
 * by escaped key then escaped value. `?b=2&a=1` signs as `a=1&b=2`. */
static char *canonicalquery(sek_pool *pool, const char *query) {
  sek_buf out;
  size_t index;
  const char *at = query;

  if (sek_empty(query)) {
    return sek_strdup(pool, "");
  }

  /* Two parallel lists rather than a sek_map: a map would collapse a
   * repeated key, and a signed query may legitimately repeat one. */
  {
    sek_list *keys = sek_list_new(pool);
    sek_list *vals = sek_list_new(pool);

    for (;;) {
      const char *amp = strchr(at, '&');
      size_t len = NULL == amp ? strlen(at) : (size_t)(amp - at);
      char *pair = sek_strndup(pool, at, len);
      const char *eq = strchr(pair, '=');

      if (NULL == eq) {
        sek_list_add(keys, sek_uriescape(pool, uridecode(pool, pair)));
        sek_list_add(vals, "");
      } else {
        char *key = sek_strndup(pool, pair, (size_t)(eq - pair));
        sek_list_add(keys, sek_uriescape(pool, uridecode(pool, key)));
        sek_list_add(vals, sek_uriescape(pool, uridecode(pool, eq + 1)));
      }

      if (NULL == amp) {
        break;
      }
      at = amp + 1;
    }

    /* An insertion sort: a signed query has a handful of pairs, and this
     * keeps the comparison - key first, then value - in one place. */
    for (index = 1; index < keys->len; index++) {
      char *key = keys->items[index];
      char *val = vals->items[index];
      size_t back = index;

      while (0 < back) {
        int cmp = strcmp(keys->items[back - 1], key);
        if (0 > cmp || (0 == cmp && 0 >= strcmp(vals->items[back - 1], val))) {
          break;
        }
        keys->items[back] = keys->items[back - 1];
        vals->items[back] = vals->items[back - 1];
        back--;
      }

      keys->items[back] = key;
      vals->items[back] = val;
    }

    sek_buf_init(&out, pool);
    for (index = 0; index < keys->len; index++) {
      if (0 < index) {
        sek_buf_addch(&out, '&');
      }
      sek_buf_add(&out, keys->items[index]);
      sek_buf_addch(&out, '=');
      sek_buf_add(&out, vals->items[index]);
    }
  }

  return out.data;
}

/* The `host` header value, the way the WHATWG URL model computes it: the
 * hostname lowercased, userinfo stripped, and the port appended ONLY when
 * it is not the scheme's default. `Host: x:443` is not what a signature
 * over `host` covers.
 *
 * Hand-split, like every other address parse in this library: a platform
 * URL type would have to agree with eleven other platforms' URL types for
 * the shared vectors to pass. */
static void splithost(sek_pool *pool, const char *url, char **host, char **path, char **query) {
  const char *rest;
  const char *stop;
  const char *authority;
  size_t authlen;
  const char *at;
  const char *colon;
  int tls = 0;
  char *bare;
  const char *port = NULL;
  const char *tail;

  if (sek_has_prefix(url, "https://")) {
    rest = url + 8;
    tls = 1;
  } else if (sek_has_prefix(url, "http://")) {
    rest = url + 7;
  } else {
    rest = url;
  }

  stop = rest;
  while ('\0' != *stop && '/' != *stop && '?' != *stop && '#' != *stop) {
    stop++;
  }

  authority = rest;
  authlen = (size_t)(stop - rest);

  /* Userinfo is stripped rather than parsed: checkaddr has already
   * refused any address that carries it, so this only ever runs on one
   * that does not. */
  {
    char *whole = sek_strndup(pool, authority, authlen);
    at = strrchr(whole, '@');
    if (NULL != at) {
      whole = sek_strdup(pool, at + 1);
    }

    /* rfind, so an IPv6 literal's own colons are not read as a port. */
    colon = strrchr(whole, ':');
    if (NULL != colon && '\0' != whole[0] && ']' != whole[strlen(whole) - 1]) {
      bare = sek_strndup(pool, whole, (size_t)(colon - whole));
      port = colon + 1;
    } else {
      bare = whole;
    }

    bare = sek_lowercase(pool, bare);

    if (NULL == port || '\0' == *port || (tls && 0 == strcmp(port, "443")) ||
        (!tls && 0 == strcmp(port, "80"))) {
      *host = bare;
    } else {
      *host = sek_fmt(pool, "%s:%s", bare, port);
    }
  }

  /* The path is the RAW, already-percent-encoded text: re-escaping it
   * would change a signature over a path that legitimately carries one. */
  tail = stop;
  {
    const char *hash = strchr(tail, '#');
    const char *mark = strchr(tail, '?');

    if (NULL != mark && (NULL == hash || mark < hash)) {
      *path = sek_strndup(pool, tail, (size_t)(mark - tail));
      *query = NULL == hash ? sek_strdup(pool, mark + 1)
                            : sek_strndup(pool, mark + 1, (size_t)(hash - mark - 1));
    } else {
      *path = NULL == hash ? sek_strdup(pool, tail) : sek_strndup(pool, tail, (size_t)(hash - tail));
      *query = sek_strdup(pool, "");
    }
  }

  if ('\0' == (*path)[0]) {
    *path = sek_strdup(pool, "/");
  }
}

/* Trimmed, and internally collapsed: AWS folds every run of spaces and
 * tabs to one space before signing, so a header value of `a  b\tc` must
 * sign as `a b c` or the service refuses the request. */
static char *foldvalue(sek_pool *pool, const char *value) {
  sek_buf out;
  size_t index = 0;
  size_t len = strlen(value);
  size_t end = len;
  int pending = 0;

  while (index < end && (' ' == value[index] || '\t' == value[index])) {
    index++;
  }
  while (end > index && (' ' == value[end - 1] || '\t' == value[end - 1])) {
    end--;
  }

  sek_buf_init(&out, pool);

  for (; index < end; index++) {
    char ch = value[index];
    if (' ' == ch || '\t' == ch) {
      pending = 1;
      continue;
    }
    if (pending) {
      sek_buf_addch(&out, ' ');
      pending = 0;
    }
    sek_buf_addch(&out, ch);
  }

  return out.data;
}

sek_map *sek_sigv4(sek_pool *pool, const sek_signing *input) {
  sek_map *headers = sek_map_new(pool);
  sek_map *out = sek_map_new(pool);
  char *host = NULL;
  char *path = NULL;
  char *query = NULL;
  char *date;
  char *scope;
  char *canonicalheaders;
  char *signedheaders;
  char *canonicalrequest;
  char *stringtosign;
  const char *session = sek_empty(input->session) ? NULL : input->session;
  unsigned char key[SEK_SHA256_LEN];
  unsigned char step[SEK_SHA256_LEN];
  size_t index;
  sek_buf headbuf;
  sek_buf namebuf;

  splithost(pool, input->url, &host, &path, &query);

  date = sek_strndup(pool, input->datetime, 8);

  /* The caller's headers first, lowercased and folded; then host,
   * x-amz-date and the session token, which are inserted AFTER so they
   * win over a caller that set them. */
  if (NULL != input->headers) {
    for (index = 0; index < input->headers->len; index++) {
      sek_map_set(headers, sek_lowercase(pool, input->headers->keys[index]),
                  foldvalue(pool, input->headers->vals[index]));
    }
  }
  sek_map_set(headers, "host", host);
  sek_map_set(headers, "x-amz-date", input->datetime);
  if (NULL != session) {
    sek_map_set(headers, "x-amz-security-token", session);
  }

  /* Sorted by name, ASCII ascending: the canonical order. */
  for (index = 1; index < headers->len; index++) {
    char *name = headers->keys[index];
    char *value = headers->vals[index];
    size_t back = index;

    while (0 < back && 0 < strcmp(headers->keys[back - 1], name)) {
      headers->keys[back] = headers->keys[back - 1];
      headers->vals[back] = headers->vals[back - 1];
      back--;
    }

    headers->keys[back] = name;
    headers->vals[back] = value;
  }

  sek_buf_init(&headbuf, pool);
  sek_buf_init(&namebuf, pool);
  for (index = 0; index < headers->len; index++) {
    sek_buf_addfmt(&headbuf, "%s:%s\n", headers->keys[index], headers->vals[index]);
    if (0 < index) {
      sek_buf_addch(&namebuf, ';');
    }
    sek_buf_add(&namebuf, headers->keys[index]);
  }
  canonicalheaders = headbuf.data;
  signedheaders = namebuf.data;

  /* Six lines. canonicalheaders already ends in a newline, so joining
   * with `\n` leaves the blank line the algorithm calls for. */
  {
    sek_buf req;
    char *method = sek_strdup(pool, input->method);
    size_t at;

    for (at = 0; '\0' != method[at]; at++) {
      method[at] = sek_upper(method[at]);
    }

    sek_buf_init(&req, pool);
    sek_buf_addfmt(&req, "%s\n%s\n%s\n%s\n%s\n%s", method, path, canonicalquery(pool, query),
                   canonicalheaders, signedheaders,
                   sek_sha256hex(pool, sek_orempty(input->body)));
    canonicalrequest = req.data;
  }

  scope = sek_fmt(pool, "%s/%s/%s/aws4_request", date, input->region, input->service);

  stringtosign = sek_fmt(pool, "AWS4-HMAC-SHA256\n%s\n%s\n%s", input->datetime, scope,
                         sek_sha256hex(pool, canonicalrequest));

  {
    char *seed = sek_fmt(pool, "AWS4%s", sek_orempty(input->secret));

    sek_hmac_sha256((const unsigned char *)seed, strlen(seed), (const unsigned char *)date,
                    strlen(date), step);
    sek_hmac_sha256(step, SEK_SHA256_LEN, (const unsigned char *)input->region,
                    strlen(input->region), key);
    sek_hmac_sha256(key, SEK_SHA256_LEN, (const unsigned char *)input->service,
                    strlen(input->service), step);
    sek_hmac_sha256(step, SEK_SHA256_LEN, (const unsigned char *)"aws4_request", 12, key);
    sek_hmac_sha256(key, SEK_SHA256_LEN, (const unsigned char *)stringtosign,
                    strlen(stringtosign), step);
  }

  /* The exact literal form, verified server-side by regex: one space
   * after the algorithm, ", " between the three components. */
  sek_map_set(out, "authorization",
              sek_fmt(pool, "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
                      sek_orempty(input->keyid), scope, signedheaders,
                      sek_hex(pool, step, SEK_SHA256_LEN)));
  sek_map_set(out, "x-amz-date", input->datetime);

  if (NULL != session) {
    sek_map_set(out, "x-amz-security-token", session);
  }

  return out;
}
