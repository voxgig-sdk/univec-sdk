// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/capability.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Capabilities (§11.1). */

#include "capability.hpp"

#include <algorithm>

#include "version.hpp"

namespace plugin {

bool capmatchvalue(const V& want, const V& got) {
  /* THIS FUNCTION IS WHAT "EVERY LEAF" MEANS, and an earlier draft of
   * the canonical did not have it: the check was a scalar compare,
   * which for any compound value is reference identity in JavaScript. A
   * requirement and a capability are declared in different places and
   * are never the same object, so `match: {limits: {max: 5}}` could not
   * be satisfied by ANY provider — including one declaring exactly
   * that. Invisible while every corpus entry is scalar, which is why
   * the go port found it and P2 did not. */
  if (ismap(want)) {
    if (!ismap(got)) return false;
    for (const auto& k : keys(want)) {
      if (!has(got, k)) return false;
      if (!capmatchvalue(get(want, k), get(got, k))) return false;
    }
    return true;
  }
  if (islist(want)) {
    if (!islist(got) || len(want) != len(got)) return false;
    for (size_t i = 0; i < len(want); i++) {
      if (!capmatchvalue(at(want, i), at(got, i))) return false;
    }
    return true;
  }
  return same(want, got);
}

bool capmatches(const V& req, const V& prov) {
  if (!same(get(req, "name"), get(prov, "name"))) return false;

  V range = get(req, "range");
  if (!isnull(range)) {
    V version = get(prov, "version");
    if (isnull(version)) return false;
    if (!satisfiesq(version, range)) return false;
  }

  /* `match` is checked against the provider's `attrs`, key by key. A
   * key the provider does not carry is a MISS, not a pass: a
   * requirement asking for `transactional: true` must not be satisfied
   * by a provider that never said. */
  V match = get(req, "match");
  if (!isnull(match)) {
    V attrs = get(prov, "attrs");
    if (isnull(attrs)) attrs = vmap();
    for (const auto& k : keys(match)) {
      if (!has(attrs, k)) return false;
      if (!capmatchvalue(get(match, k), get(attrs, k))) return false;
    }
  }

  return true;
}

/* The rank, as a strict weak ordering over two candidates. Ordering is
 * a TOTAL rank on purpose: without one, "any provider satisfies" is
 * true of the GRAPH and useless to the PLUGIN — two ports could bind
 * different `store` instances, both resolve green, and behave
 * differently, which is precisely the divergence a shared corpus exists
 * to catch. */
static bool better(const V& a, const V& b) {
  V ap = get(a, "provides");
  V bp = get(b, "provides");

  V av = get(ap, "version");
  V bv = get(bp, "version");
  bool ahas = !isnull(av), bhas = !isnull(bv);
  if (ahas != bhas) return ahas;             /* a version beats none */
  if (ahas && bhas) {
    int c = 0;
    try {
      /* HIGHEST version first, so the comparison is reversed. */
      c = vercmp(parseversion(bv), parseversion(av));
    }
    catch (const PluginError&) {
      c = 0;
    }
    if (0 != c) return 0 > c;
  }

  double apri = isnum(get(ap, "priority")) ? asnum(get(ap, "priority")) : 0.0;
  double bpri = isnum(get(bp, "priority")) ? asnum(get(bp, "priority")) : 0.0;
  if (apri != bpri) return apri < bpri;      /* LOWEST priority first */

  return asnum(get(a, "pos")) < asnum(get(b, "pos"));
}

V resolvecapability(const V& req, const V& candidates) {
  std::vector<V> hits;
  for (size_t i = 0; i < len(candidates); i++) {
    V c = at(candidates, i);
    if (capmatches(req, get(c, "provides"))) hits.push_back(c);
  }

  /* `std::sort` is not stable, and §6.3's tie rules make the order
   * observable — so `better` is a TOTAL order (it falls through to
   * `pos`, which is unique) and stability is not relied on. An earlier
   * reading that stopped at `priority` would have left ties to the
   * sort's discretion, which is exactly the per-port divergence the
   * ranking exists to remove. */
  std::sort(hits.begin(), hits.end(), better);

  V out = vlist();
  for (const auto& h : hits) push(out, h);
  return out;
}

}  // namespace plugin
