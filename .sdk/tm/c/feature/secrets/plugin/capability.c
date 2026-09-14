// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/capability.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Capabilities (§11.1). */

#include <stdlib.h>
#include <string.h>

#include "capability.h"
#include "version.h"

bool capmatchvalue(Value *want, Value *got) {
  /* THIS FUNCTION IS WHAT "EVERY LEAF" MEANS, and an earlier draft of
   * the canonical did not have it: the check was a scalar compare,
   * which for any compound value is reference identity in JavaScript. A
   * requirement and a capability are declared in different places and
   * are never the same object, so `match: {limits: {max: 5}}` could not
   * be satisfied by ANY provider — including one declaring exactly
   * that. Invisible while every corpus entry is scalar, which is why
   * the go port found it and P2 did not. */
  if (vismap(want)) {
    if (!vismap(got)) return false;
    const char **keys;
    size_t n = vkeys(want, &keys);
    for (size_t i = 0; i < n; i++) {
      if (!vhas(got, keys[i])) return false;
      if (!capmatchvalue(vget(want, keys[i]), vget(got, keys[i]))) return false;
    }
    return true;
  }
  if (vislist(want)) {
    if (!vislist(got) || vlen(want) != vlen(got)) return false;
    for (size_t i = 0; i < vlen(want); i++) {
      if (!capmatchvalue(vat(want, i), vat(got, i))) return false;
    }
    return true;
  }
  return vsame(want, got);
}

bool capmatches(Value *req, Value *prov) {
  Value *rname = vget(req, "name");
  Value *pname = vget(prov, "name");
  if (!vsame(rname, pname)) return false;

  Value *range = vget(req, "range");
  if (!visnull(range)) {
    Value *version = vget(prov, "version");
    if (visnull(version)) return false;
    if (!satisfiesq(version, range)) return false;
  }

  /* `match` is checked against the provider's `attrs`, key by key. A
   * key the provider does not carry is a MISS, not a pass: a
   * requirement asking for `transactional: true` must not be satisfied
   * by a provider that never said. */
  Value *match = vget(req, "match");
  if (!visnull(match)) {
    Value *attrs = vget(prov, "attrs");
    if (visnull(attrs)) attrs = vmap();
    const char **keys;
    size_t n = vkeys(match, &keys);
    for (size_t i = 0; i < n; i++) {
      if (!vhas(attrs, keys[i])) return false;
      if (!capmatchvalue(vget(match, keys[i]), vget(attrs, keys[i]))) {
        return false;
      }
    }
  }

  return true;
}

/* The rank, as a comparison over two candidates. Ordering is a total
 * rank on purpose: without one, "any provider satisfies" is true of the
 * GRAPH and useless to the PLUGIN — two ports could bind different
 * `store` instances, both resolve green, and behave differently, which
 * is precisely the divergence a shared corpus exists to catch. */
static int rank(const void *pa, const void *pb) {
  Value *a = *(Value *const *)pa;
  Value *b = *(Value *const *)pb;
  Value *ap = vget(a, "provides");
  Value *bp = vget(b, "provides");

  Value *av = vget(ap, "version");
  Value *bv = vget(bp, "version");
  bool ahas = !visnull(av), bhas = !visnull(bv);
  if (ahas != bhas) return ahas ? -1 : 1;   /* a version beats none */
  if (ahas && bhas) {
    /* HIGHEST version first, so the comparison is reversed. */
    CatchFrame f;
    int c = 0;
    if (0 == PLUGIN_TRY(&f)) {
      c = vercmp(parseversion(bv), parseversion(av));
      PLUGIN_END(&f);
    }
    else {
      c = 0;
    }
    if (0 != c) return c;
  }

  double apri = visnum(vget(ap, "priority")) ? vasnum(vget(ap, "priority")) : 0.0;
  double bpri = visnum(vget(bp, "priority")) ? vasnum(vget(bp, "priority")) : 0.0;
  if (apri != bpri) return apri < bpri ? -1 : 1;   /* LOWEST priority first */

  double apos = visnum(vget(a, "pos")) ? vasnum(vget(a, "pos")) : 0.0;
  double bpos = visnum(vget(b, "pos")) ? vasnum(vget(b, "pos")) : 0.0;
  if (apos != bpos) return apos < bpos ? -1 : 1;
  return 0;
}

Value *resolvecapability(Value *req, Value *candidates) {
  size_t n = vlen(candidates);
  Value **hits = (Value **)arena_alloc(sizeof(Value *) * (n + 1));
  size_t count = 0;
  for (size_t i = 0; i < n; i++) {
    Value *c = vat(candidates, i);
    if (capmatches(req, vget(c, "provides"))) hits[count++] = c;
  }

  /* A STABLE SORT. `qsort` is not stable, and §6.3's tie rules make the
   * order observable — so `rank` is a TOTAL order (it falls through to
   * `pos`, which is unique) and stability is not relied on. An earlier
   * reading that stopped at `priority` would have left ties to qsort's
   * discretion, which is exactly the per-port divergence the ranking
   * exists to remove. */
  if (1 < count) qsort(hits, count, sizeof(Value *), rank);

  Value *out = vlist();
  for (size_t i = 0; i < count; i++) vpush(out, hits[i]);
  return out;
}
