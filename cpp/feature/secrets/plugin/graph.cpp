// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/graph.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Whole-graph resolution (§11.4) — a phase, not a discovery.
 *
 * "Activate, and wait in `pending` if you must" is correct and, on its
 * own, produces a terrible experience: apply twenty instances against a
 * registry missing one thing and you get NINETEEN pending rows and no
 * statement of what is actually wrong.
 *
 * `resolvegraph` is a PURE FUNCTION of the registry and the intended
 * activation set. No callbacks run, no state changes, nothing is
 * touched. It answers for the whole graph at once which instances can
 * be live, and for each blocked one THE SPECIFIC REQUIREMENT that is
 * unmet, and why.
 *
 * The failure mode being designed against is a famous one: OSGi's
 * resolver is correct and its diagnostics are legendarily unusable. A
 * resolver that says "blocked" without saying WHY has moved the problem
 * rather than solved it, so `why` is part of the contract. */

#include "graph.hpp"

#include <algorithm>

#include "capability.hpp"
#include "ref.hpp"
#include "version.hpp"

namespace plugin {

static V candidates(const V& byref, const V& name) {
  V out = vlist();
  /* A NODE SATISFIES ITS OWN REF (§11.1), and this is where the graph
   * learned it. Considering only declared capabilities made `resolve`
   * answer `absent` about a provider sitting right there and live —
   * §11.4's whole job is explaining the graph the runtime reconciles,
   * and it was explaining a different one. Canonical (§4 rule 5), and
   * tolerant, because a capability name need not be a well-formed ref. */
  std::string asref;
  bool isaref = isstr(name) && tryref(asstr(name), asref);

  for (const auto& r : sortedkeys(byref)) {
    V node = get(byref, r);
    V pos = get(node, "pos");
    /* The ref match WINS OUTRIGHT for that node, as at runtime: one
     * candidate, not two, for a node both named `b` and providing `b` —
     * without the skip the blocked-chain explanation named it twice. */
    if (isaref && r == asref) {
      V prov = vmap();
      set(prov, "name", name);
      V cand = vmap();
      set(cand, "ref", get(node, "ref"));
      set(cand, "pos", isnum(pos) ? pos : vnum(0));
      set(cand, "provides", prov);
      push(out, cand);
      continue;
    }
    V provides = get(node, "provides");
    for (size_t j = 0; j < len(provides); j++) {
      V p = at(provides, j);
      if (same(get(p, "name"), name)) {
        V cand = vmap();
        set(cand, "ref", get(node, "ref"));
        set(cand, "pos", isnum(pos) ? pos : vnum(0));
        set(cand, "provides", p);
        push(out, cand);
      }
    }
  }
  return out;
}

static V blockedof(const V& node, const V& unmet, const V& why) {
  V out = vmap();
  set(out, "ref", get(node, "ref"));
  set(out, "unmet", unmet);
  set(out, "why", why);
  return out;
}

static V why1(const std::string& kind) {
  V w = vmap();
  set(w, "kind", vstr(kind));
  return w;
}

static V sortedstrings(std::vector<std::string> v) {
  std::sort(v.begin(), v.end());
  V out = vlist();
  for (const auto& s : v) push(out, vstr(s));
  return out;
}

/* The FIRST unmet requirement, with the most specific explanation
 * available. Order matters: "no provider at all" and "a provider at the
 * wrong version" are different problems and a reader must not have to
 * guess which they have. */
static V firstunmet(const V& node, const V& byref, const V& resolved) {
  V reqs = get(node, "requires");
  for (size_t ri = 0; ri < len(reqs); ri++) {
    V req = at(reqs, ri);
    if (truthy(get(req, "optional"))) continue;

    V name = get(req, "name");
    V all = candidates(byref, name);
    if (0 == len(all)) return blockedof(node, name, why1("absent"));

    V ok = resolvecapability(req, all);
    if (0 < len(ok)) {
      /* A provider exists and matches — but if none of them is itself
       * resolved, this node is blocked BEHIND it, and the chain is the
       * useful answer rather than "unmet". */
      bool live = false;
      for (size_t i = 0; i < len(ok); i++) {
        if (has(resolved, asstr(get(at(ok, i), "ref")))) { live = true; break; }
      }
      if (live) continue;

      std::vector<std::string> chain;
      for (size_t i = 0; i < len(ok); i++) {
        chain.push_back(asstr(get(at(ok, i), "ref")));
      }
      V w = why1("blocked");
      set(w, "chain", sortedstrings(chain));
      return blockedof(node, name, w);
    }

    /* Providers exist and none matched. Say which test failed. */
    V range = get(req, "range");
    if (!isnull(range)) {
      std::vector<std::string> found;
      for (size_t i = 0; i < len(all); i++) {
        V prov = get(at(all, i), "provides");
        V version = get(prov, "version");
        if (isnull(version) || !satisfiesq(version, range)) {
          found.push_back(isnull(version) ? "(none)" : asstr(version));
        }
      }
      if (!found.empty()) {
        V w = why1("version");
        set(w, "range", range);
        set(w, "found", sortedstrings(found));
        return blockedof(node, name, w);
      }
    }

    V match = get(req, "match");
    if (!isnull(match)) {
      for (size_t i = 0; i < len(all); i++) {
        V prov = get(at(all, i), "provides");
        V attrs = get(prov, "attrs");
        if (isnull(attrs)) attrs = vmap();
        for (const auto& k : sortedkeys(match)) {
          /* The same recursive partial match the selection applies, so
           * a nested requirement that FAILED the selection is also the
           * one the diagnosis names (§11.4). */
          if (!has(attrs, k) || !capmatchvalue(get(match, k), get(attrs, k))) {
            V w = why1("match");
            set(w, "failing", vstr(k));
            set(w, "want", get(match, k));
            set(w, "found", get(attrs, k));
            return blockedof(node, name, w);
          }
        }
      }
    }

    return blockedof(node, name, why1("absent"));
  }
  return nullptr;
}

V resolvegraph(const V& nodes) {
  V byref = vmap();
  for (size_t i = 0; i < len(nodes); i++) {
    V n = at(nodes, i);
    set(byref, asstr(get(n, "ref")), n);
  }

  V resolved = vmap();

  /* Fixed point: a node resolves when every mandatory requirement is
   * met by an ALREADY-RESOLVED provider. Iterating to a fixed point is
   * what makes a provider that is itself blocked propagate, rather than
   * each node being judged against the raw registry. */
  bool moved = true;
  while (moved) {
    moved = false;
    for (size_t i = 0; i < len(nodes); i++) {
      V n = at(nodes, i);
      const std::string ref = asstr(get(n, "ref"));
      if (has(resolved, ref)) continue;
      if (!firstunmet(n, byref, resolved)) {
        set(resolved, ref, vbool(true));
        moved = true;
      }
    }
  }

  V blocked = vmap();
  for (size_t i = 0; i < len(nodes); i++) {
    V n = at(nodes, i);
    const std::string ref = asstr(get(n, "ref"));
    if (has(resolved, ref)) continue;
    V why = firstunmet(n, byref, resolved);
    if (why) set(blocked, ref, why);
  }

  V resolvedlist = vlist();
  for (const auto& k : sortedkeys(resolved)) push(resolvedlist, vstr(k));

  V blockedlist = vlist();
  for (const auto& k : sortedkeys(blocked)) push(blockedlist, get(blocked, k));

  V out = vmap();
  set(out, "resolved", resolvedlist);
  set(out, "blocked", blockedlist);
  return out;
}

}  // namespace plugin
