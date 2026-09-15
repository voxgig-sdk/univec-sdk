// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/encode.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The two encoders every HTTP store needs: strict base64 decoding and
 * RFC 3986 percent-encoding.
 *
 * WITH THE TRANSPORT, NOT WITH THE SIGNER, and that placement is the
 * whole reason this file exists. Percent-encoding builds the URLs of
 * four stores that hash nothing - azure, onepassword, doppler,
 * infisical - and base64 decodes an AWS binary secret and a GCP payload.
 * Leaving either beside the SigV4 code would put SHA-256 in the link of
 * every one of them, because a static archive is pulled in an object at a
 * time. SigV4 depends on this file; this file depends on nothing but the
 * core.
 */

#define _POSIX_C_SOURCE 200809L

#include <string.h>

#include "support.h"

/* ---- base64, decode only ------------------------------------------- */

static int unb64digit(char ch) {
  if ('A' <= ch && 'Z' >= ch) {
    return ch - 'A';
  }
  if ('a' <= ch && 'z' >= ch) {
    return ch - 'a' + 26;
  }
  if ('0' <= ch && '9' >= ch) {
    return ch - '0' + 52;
  }
  if ('+' == ch) {
    return 62;
  }
  if ('/' == ch) {
    return 63;
  }
  return -1;
}

/* Strict, and that is the point. A lenient decoder skips bytes outside
 * the alphabet and hands back plausible bytes for a corrupted payload -
 * and this library then returns those bytes AS THE SECRET. Anything
 * rejected here is an error at its call site, never a miss. */
unsigned char *sek_unbase64(sek_pool *pool, const char *text, size_t *outlen) {
  sek_buf packed;
  size_t index;
  size_t pad = 0;
  unsigned char *out;
  size_t at = 0;

  if (NULL == text) {
    return NULL;
  }

  /* Whitespace is stripped first: the canonical function accepts embedded
   * newlines, which a strict decoder would otherwise reject. */
  sek_buf_init(&packed, pool);
  for (index = 0; '\0' != text[index]; index++) {
    char ch = text[index];
    if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch || '\v' == ch || '\f' == ch) {
      continue;
    }
    sek_buf_addch(&packed, ch);
  }

  if (0 != packed.len % 4) {
    return NULL;
  }

  while (2 > pad && pad < packed.len && '=' == packed.data[packed.len - 1 - pad]) {
    pad++;
  }

  for (index = 0; index + pad < packed.len; index++) {
    if (0 > unb64digit(packed.data[index])) {
      return NULL;
    }
  }

  out = (unsigned char *)sek_alloc(pool, packed.len / 4 * 3 + 4);

  for (index = 0; index + 3 < packed.len; index += 4) {
    int a = unb64digit(packed.data[index]);
    int b = unb64digit(packed.data[index + 1]);
    int c = unb64digit(packed.data[index + 2]);
    int d = unb64digit(packed.data[index + 3]);
    unsigned int acc;

    if (0 > a || 0 > b) {
      return NULL;
    }

    acc = (unsigned int)(a << 18) | (unsigned int)(b << 12);
    out[at++] = (unsigned char)((acc >> 16) & 0xff);

    if (0 <= c) {
      acc |= (unsigned int)(c << 6);
      out[at++] = (unsigned char)((acc >> 8) & 0xff);
    }
    if (0 <= d) {
      acc |= (unsigned int)d;
      out[at++] = (unsigned char)(acc & 0xff);
    }
  }

  out[at] = '\0';
  *outlen = at;

  return out;
}

/* ---- percent-encoding ---------------------------------------------- */

/* RFC 3986 escaping, stricter than any stdlib encoder: the unreserved set
 * is exactly A-Za-z0-9-_.~ and everything else, byte by byte over UTF-8,
 * becomes %XX with UPPERCASE hex. `!'()*` are escaped, which is the gap
 * against the usual encodeURIComponent. */
char *sek_uriescape(sek_pool *pool, const char *text) {
  static const char digits[] = "0123456789ABCDEF";
  sek_buf out;
  size_t index;

  sek_buf_init(&out, pool);

  for (index = 0; NULL != text && '\0' != text[index]; index++) {
    unsigned char ch = (unsigned char)text[index];

    if (('A' <= ch && 'Z' >= ch) || ('a' <= ch && 'z' >= ch) || ('0' <= ch && '9' >= ch) ||
        '-' == ch || '_' == ch || '.' == ch || '~' == ch) {
      sek_buf_addch(&out, (char)ch);
    } else {
      sek_buf_addch(&out, '%');
      sek_buf_addch(&out, digits[(ch >> 4) & 0x0f]);
      sek_buf_addch(&out, digits[ch & 0x0f]);
    }
  }

  return out.data;
}

