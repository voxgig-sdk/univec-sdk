// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/env.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Environment overrides (§9.5) — level 7 of the ladder.
 *
 * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
 *
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 *
 * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
 * OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
 * `_`. But `_` is legal in a name and in a tag, and the mapping folds
 * case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
 *
 * Rather than restrict a grammar the rest of the stack already uses,
 * the host DETECTS THE COLLISION: it encodes every ref it holds, and a
 * key two refs claim is `plugin_env_ambiguous`, naming both.
 *
 * Pure: a function over a string map and a ref set, so the corpus tests
 * it without touching a real environment. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "env.h"
#include "ref.h"

#define PREFIX "VOXGIG_PLUGIN_"

const char *encoderef(const char *ref) {
  size_t n = strlen(ref);
  char *out = (char *)arena_alloc(n * 2 + 1);
  size_t j = 0;
  for (size_t i = 0; i < n; i++) {
    char c = ref[i];
    if ('$' == c) { out[j++] = '_'; out[j++] = '_'; }
    else if ('.' == c) { out[j++] = '_'; }
    else if ('a' <= c && 'z' >= c) { out[j++] = (char)(c - 'a' + 'A'); }
    else { out[j++] = c; }
  }
  out[j] = '\0';
  return out;
}

static void checkreserved(const char *ref, Value *reserved) {
  if (!vislist(reserved) || 0 == vlen(reserved)) return;
  const char *name = refname(ref);
  for (size_t i = 0; i < vlen(reserved); i++) {
    Value *r = vat(reserved, i);
    if (visstr(r) && 0 == strcmp(vasstr(r), name)) {
      size_t sz = strlen(ref) + 48;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "ref is reserved by the host: %s", ref);
      fail("plugin_ref_reserved", text, details1("ref", vstr(ref)));
    }
  }
}

/* Values parse as JSON, FALLING BACK TO STRING — so `8080` is a number,
 * `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
 * looks like rather than a parse error. */
static Value *parsevalue(const char *v) {
  const char *err = NULL;
  Value *parsed = vparse(v, &err);
  return NULL == parsed ? vstr(v) : parsed;
}

static int bylen_desc(const void *a, const void *b) {
  const char *x = *(const char *const *)a;
  const char *y = *(const char *const *)b;
  size_t lx = strlen(x), ly = strlen(y);
  if (lx != ly) return lx > ly ? -1 : 1;
  return strcmp(x, y);
}

Value *applyenv(Value *input) {
  Value *env = vget(input, "env");
  if (!vismap(env)) env = vmap();
  Value *refsin = vget(input, "refs");
  Value *reserved = vget(input, "reserved");

  Value *out = vmap();
  Value *options = vmap();
  Value *active = vlist();
  Value *inactive = vlist();
  vset(out, "options", options);
  vset(out, "active", active);
  vset(out, "inactive", inactive);

  /* Encode every ref the host holds, and refuse a key that two of them
   * claim. Done UP FRONT so the collision is reported even when no
   * environment variable exercises it — a latent ambiguity is still an
   * ambiguity, and finding it at deploy time is the failure this exists
   * to prevent. */
  Value *byencoded = vmap();
  if (vislist(refsin)) {
    for (size_t i = 0; i < vlen(refsin); i++) {
      const char *r = canonref(vat(refsin, i));
      const char *e = encoderef(r);
      Value *list = vget(byencoded, e);
      if (visnull(list)) { list = vlist(); vset(byencoded, e, list); }
      vpush(list, vstr(r));
    }
  }

  const char **encs;
  size_t nenc = vsortedkeys(byencoded, &encs);
  for (size_t i = 0; i < nenc; i++) {
    Value *claims = vget(byencoded, encs[i]);
    if (1 < vlen(claims)) {
      const char *a = vasstr(vat(claims, 0));
      const char *b = vasstr(vat(claims, 1));
      const char *lo = 0 <= strcmp(a, b) ? b : a;
      const char *hi = 0 <= strcmp(a, b) ? a : b;
      Value *pair = vlist();
      vpush(pair, vstr(lo));
      vpush(pair, vstr(hi));
      size_t sz = strlen(encs[i]) + strlen(lo) + strlen(hi) + 64;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "refs collide in the environment encoding as %s: %s, %s",
               encs[i], lo, hi);
      Value *details = vmap();
      vset(details, "encoded", vstr(encs[i]));
      vset(details, "refs", pair);
      fail("plugin_env_ambiguous", text, details);
    }
  }

  /* LONGEST encoded ref first, so `retry$fast` wins over `retry` on
   * `RETRY__FAST_MIN`. Shortest-first would read the tag as a path. */
  const char **order = (const char **)arena_alloc(sizeof(char *) * (nenc + 1));
  for (size_t i = 0; i < nenc; i++) order[i] = encs[i];
  if (1 < nenc) qsort((void *)order, nenc, sizeof(char *), bylen_desc);

  const char **keys;
  size_t nk = vsortedkeys(env, &keys);
  size_t plen = strlen(PREFIX);

  for (size_t ki = 0; ki < nk; ki++) {
    const char *key = keys[ki];
    if (0 != strncmp(key, PREFIX, plen)) continue;
    const char *rest = key + plen;
    Value *raw = vget(env, key);
    const char *val = visstr(raw) ? vasstr(raw) : "";

    if (0 == strcmp(rest, "PROFILE")) {
      vset(out, "profile", vstr(val));
      continue;
    }

    if (0 == strcmp(rest, "ACTIVE") || 0 == strcmp(rest, "INACTIVE")) {
      bool isactive = 0 == strcmp(rest, "ACTIVE");
      const char *p = val;
      while ('\0' != *p) {
        while (' ' == *p || '\t' == *p) p++;
        const char *start = p;
        while ('\0' != *p && ',' != *p) p++;
        const char *end = p;
        while (end > start && (' ' == end[-1] || '\t' == end[-1])) end--;
        if (end > start) {
          const char *piece = arena_strndup(start, (size_t)(end - start));
          const char *c = canonref(vstr(piece));
          /* The reservation covers EVERY input layer (§9.1).
           * VOXGIG_PLUGIN_INACTIVE=station is easier to set than
           * editing a config file, and INACTIVE has the final word — so
           * guarding documents alone would leave the one lever this
           * mechanism exists to deny wide open. */
          checkreserved(c, reserved);
          vpush(isactive ? active : inactive, vstr(c));
        }
        if (',' == *p) p++;
      }
      continue;
    }

    const char *enc = NULL;
    for (size_t i = 0; i < nenc; i++) {
      size_t el = strlen(order[i]);
      if (0 == strcmp(rest, order[i]) ||
          (0 == strncmp(rest, order[i], el) && '_' == rest[el])) {
        enc = order[i];
        break;
      }
    }
    if (NULL == enc) continue;   /* not for any ref this host holds */

    const char *ref = vasstr(vat(vget(byencoded, enc), 0));
    checkreserved(ref, reserved);

    if (0 == strcmp(rest, enc)) continue;   /* a ref with no path sets nothing */

    const char *pathtext = rest + strlen(enc) + 1;
    Value *node = vget(options, ref);
    if (visnull(node)) { node = vmap(); vset(options, ref, node); }

    const char *seg = pathtext;
    for (;;) {
      const char *dot = strchr(seg, '_');
      if (NULL == dot) break;
      char *piece = arena_strndup(seg, (size_t)(dot - seg));
      for (char *q = piece; '\0' != *q; q++) {
        if ('A' <= *q && 'Z' >= *q) *q = (char)(*q - 'A' + 'a');
      }
      Value *next = vget(node, piece);
      if (!vismap(next)) { next = vmap(); vset(node, piece, next); }
      node = next;
      seg = dot + 1;
    }
    char *leaf = arena_strdup(seg);
    for (char *q = leaf; '\0' != *q; q++) {
      if ('A' <= *q && 'Z' >= *q) *q = (char)(*q - 'A' + 'a');
    }
    vset(node, leaf, parsevalue(val));
  }

  return out;
}
