// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/version.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Versions and ranges (§11.2). */

#include <stdio.h>
#include <string.h>

#include "version.h"

/* A COMPONENT IS BOUNDED, like a ref is (§4's 1024).
 *
 * The grammar admits an unbounded digit sequence, and every language
 * then disagrees about what happens past its integer range: JavaScript
 * silently loses precision, Go's Atoi errors (and a port ignoring that
 * gets 0), C overflows, Python is exact. `satisfies("0",
 * "9223372036854775808")` was false in the canonical and true in go,
 * from the same corpus.
 *
 * 2^31-1 because every port has a signed 32-bit integer, and no real
 * version has ever needed more. Stated rather than left to arithmetic
 * nobody agrees on. Found by review of the go port. */
#define COMPONENT_MAX 2147483647L

/* `^(\d+)(?:\.(\d+))?(?:\.(\d+))?$`, by hand: three components, digits
 * only, no leading sign, no empty component. Written out rather than
 * handed to <regex.h> because the bound below has to be checked per
 * component anyway, and a regex that matched then needed re-scanning
 * would be the worse of both. */
static bool parse3(const char *s, long *out, bool *overflow) {
  out[0] = out[1] = out[2] = 0;
  *overflow = false;
  if (NULL == s || '\0' == s[0]) return false;

  size_t i = 0;
  for (int part = 0; part < 3; part++) {
    if ('\0' == s[i]) return 0 < part; /* fewer than three is fine */
    if (0 < part) {
      if ('.' != s[i]) return false;
      i++;
    }
    size_t start = i;
    long acc = 0;
    while ('0' <= s[i] && '9' >= s[i]) {
      if (!*overflow) {
        acc = acc * 10 + (s[i] - '0');
        if (COMPONENT_MAX < acc) *overflow = true;
      }
      i++;
    }
    if (start == i) return false; /* an empty component is not a number */
    out[part] = acc;
  }
  return '\0' == s[i];
}

static Value *triple(const long *n) {
  Value *out = vlist();
  for (int i = 0; i < 3; i++) vpush(out, vnum((double)n[i]));
  return out;
}

Value *parserange(Value *range) {
  if (!visstr(range) || '\0' == vasstr(range)[0]) {
    const char *shown = visstr(range) ? vasstr(range) : "";
    size_t sz = strlen(shown) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "invalid range: %s", shown);
    fail("plugin_bad_range", text,
         details1("range", visnull(range) ? vnull() : range));
  }

  const char *s = vasstr(range);
  /* Two forms and no more (§11.2):
   *   '2.1'   >= 2.1.0 and < 3.0.0
   *   '~2.1'  >= 2.1.0 and < 2.2.0 */
  bool tilde = '~' == s[0];
  const char *body = tilde ? s + 1 : s;

  long n[3];
  bool overflow = false;
  if (!parse3(body, n, &overflow) || overflow) {
    size_t sz = strlen(s) + 64;
    char *text = (char *)arena_alloc(sz);
    if (overflow) snprintf(text, sz, "version component out of range in %s", s);
    else snprintf(text, sz, "invalid range: %s", s);
    fail("plugin_bad_range", text, details1("range", range));
  }

  long lo[3] = { n[0], n[1], n[2] };
  long hi[3];
  if (tilde) { hi[0] = n[0]; hi[1] = n[1] + 1; hi[2] = 0; }
  else { hi[0] = n[0] + 1; hi[1] = 0; hi[2] = 0; }

  Value *out = vmap();
  vset(out, "lo", triple(lo));
  vset(out, "hi", triple(hi));
  return out;
}

Value *parseversion(Value *version) {
  if (!visstr(version)) {
    fail("plugin_bad_range", "invalid version",
         details1("version", visnull(version) ? vnull() : version));
  }
  const char *s = vasstr(version);
  long n[3];
  bool overflow = false;
  if (!parse3(s, n, &overflow) || overflow) {
    size_t sz = strlen(s) + 64;
    char *text = (char *)arena_alloc(sz);
    /* `plugin_bad_range` either way — the same code the rest of the
     * grammar's failures use, because "this is not a version I can
     * compare" is one fact however it went wrong. */
    if (overflow) snprintf(text, sz, "version component out of range in %s", s);
    else snprintf(text, sz, "invalid version: %s", s);
    fail("plugin_bad_range", text, details1("version", version));
  }
  return triple(n);
}

int vercmp(Value *a, Value *b) {
  for (size_t i = 0; i < 3; i++) {
    double x = visnum(vat(a, i)) ? vasnum(vat(a, i)) : 0.0;
    double y = visnum(vat(b, i)) ? vasnum(vat(b, i)) : 0.0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

bool satisfies(Value *version, Value *range) {
  Value *v = parseversion(version);
  Value *r = parserange(range);
  return 0 <= vercmp(v, vget(r, "lo")) && 0 > vercmp(v, vget(r, "hi"));
}

bool satisfiesq(Value *version, Value *range) {
  /* `satisfies` for the internal callers that treat an unparseable
   * version or range as "does not satisfy" — Capability and Graph, both
   * of which run over data the corpus has already admitted. */
  CatchFrame f;
  bool out = false;
  if (0 == PLUGIN_TRY(&f)) {
    out = satisfies(version, range);
    PLUGIN_END(&f);
  }
  else {
    out = false;
  }
  return out;
}
