// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/depend.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dependency cardinality, policy, and the restart graph (§11.3).
 *
 * TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
 * because only it knows what it can cope with:
 *
 *                | static (default)          | dynamic
 *   -------------|---------------------------|--------------------------
 *   mandatory    | unmet -> pending;         | unmet -> pending;
 *   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
 *                |          recursively      |          notified
 *   -------------|---------------------------|--------------------------
 *   optional:true| never gates activation;   | never gates activation;
 *                | a change deactivates and  | a change is a
 *                | reactivates               | notification, nothing else
 *
 * `dynamic` means the plugin has said, IN WRITING, that it can survive
 * its provider being swapped underneath it. It is not the default
 * because most plugins cannot, and the cost of wrongly assuming they
 * can is a live instance holding a dead reference. */

#include "depend.hpp"

#include <algorithm>

#include "ref.hpp"

namespace plugin {

/* A bare string is shorthand for `{name}`. */
V normrequire(const V& r) {
  if (isstr(r)) {
    V out = vmap();
    set(out, "name", r);
    return out;
  }
  return ismap(r) ? r : vmap();
}

/* BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
 *
 * The instance-level `policy` and `optional` list are how a DOCUMENT
 * states the axis without editing the definition, and they apply to
 * every requirement. The per-requirement form is strictly more
 * expressive: an instance that is `static` on its store and `dynamic`
 * on its metrics cannot be written at all at the instance level, and
 * that is the ordinary case rather than an exotic one.
 *
 * `optional` UNIONS rather than overriding — both spellings say this
 * requirement need not gate activation, and there is no reading under
 * which one of them means "actually, mandatory". */
V requirements(const V& options) {
  V raw = get(options, "requires");
  V marked = get(options, "optional");
  V fallback = get(options, "policy");

  V out = vlist();
  for (size_t i = 0; i < len(raw); i++) {
    V r = normrequire(at(raw, i));
    V o = vmap();
    for (const auto& k : keys(r)) set(o, k, get(r, k));

    bool opt = truthy(get(r, "optional"));
    if (!opt && islist(marked)) {
      for (size_t j = 0; j < len(marked); j++) {
        if (same(at(marked, j), get(r, "name"))) { opt = true; break; }
      }
    }
    if (opt) set(o, "optional", vbool(true));

    if (isnull(get(o, "policy")) && !isnull(fallback)) set(o, "policy", fallback);
    push(out, o);
  }
  return out;
}

/* Does losing this requirement's SELECTED provider restart the
 * consumer? The mandatory ones under `static`, and the `static`
 * optional ones — both make a capability change deactivate and
 * reactivate. `dynamic` never restarts. */
bool restartsonloss(const V& r) {
  V p = get(r, "policy");
  const std::string policy = isstr(p) ? asstr(p) : "static";
  return "dynamic" != policy;
}

/* Does an unmet requirement keep the consumer out of `live`?
 *
 * CARDINALITY ALONE DECIDES THIS, NOT POLICY. `dynamic` is a statement
 * about surviving a SWAP, not about starting without the thing at all —
 * a mandatory-dynamic consumer still waits in `pending` for its first
 * provider. Conflating the two would let a plugin that declared it can
 * cope with replacement activate with nothing to call. */
bool gatesactivation(const V& r) { return true != asbool(get(r, "optional")); }

/* Edges that can cause a restart, which is exactly the set a cycle must
 * be detected over (§11.3): the mandatory requirements AND THE `static`
 * OPTIONAL ONES, because both make a capability change deactivate and
 * reactivate the consumer — and a cycle of restarts does not settle.
 *
 * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
 * exclusion was for. An earlier draft of §11.3 excluded EVERY optional
 * edge and thereby admitted the non-terminating case it was trying to
 * permit. */
bool restartcausing(const V& r) {
  return gatesactivation(r) || restartsonloss(r);
}

V dependencycycle(const V& nodes) {
  /* TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
   * matched differently — a capability by its exact name, a ref through
   * the canonical spelling (§4 rule 5) — and one map keyed by both can
   * only do one of them. Keyed by both and looked up raw, a cycle
   * spelled `a$`/`b$` finds no providers and EVADES the load-time check
   * that exists to catch a non-terminating reconcile. */
  V bycap = vmap();
  V isref = vmap();
  for (size_t i = 0; i < len(nodes); i++) {
    V n = at(nodes, i);
    const std::string nref = asstr(get(n, "ref"));
    set(isref, nref, vbool(true));
    V provides = get(n, "provides");
    for (size_t j = 0; j < len(provides); j++) {
      const std::string cap = asstr(at(provides, j));
      V l = get(bycap, cap);
      if (isnull(l)) { l = vlist(); set(bycap, cap, l); }
      push(l, vstr(nref));
    }
  }

  V edges = vmap();
  for (size_t i = 0; i < len(nodes); i++) {
    V n = at(nodes, i);
    const std::string nref = asstr(get(n, "ref"));
    std::vector<std::string> out;
    V reqs = get(n, "requires");
    for (size_t j = 0; j < len(reqs); j++) {
      V r = at(reqs, j);
      if (!restartcausing(r)) continue;
      const std::string rname = asstr(get(r, "name"));
      std::vector<std::string> from;
      V caps = get(bycap, rname);
      for (size_t k = 0; k < len(caps); k++) from.push_back(asstr(at(caps, k)));
      /* A node satisfies its own name AS A REF (§11.1), canonically —
       * exactly what `providersof` does at runtime, so the load-time
       * graph and the running one agree about what an edge is. */
      std::string asref;
      if (tryref(rname, asref) && has(isref, asref) &&
          from.end() == std::find(from.begin(), from.end(), asref)) {
        from.push_back(asref);
      }
      for (const auto& p : from) {
        if (p != nref && out.end() == std::find(out.begin(), out.end(), p)) {
          out.push_back(p);
        }
      }
    }
    std::sort(out.begin(), out.end());
    V sorted = vlist();
    for (const auto& p : out) push(sorted, vstr(p));
    set(edges, nref, sorted);
  }

  /* Iterative DFS with an explicit stack: twenty ports, and several of
   * them have no recursion budget worth relying on. */
  enum { WHITE = 0, GREY = 1, BLACK = 2 };
  V colour = vmap();
  for (size_t i = 0; i < len(nodes); i++) {
    set(colour, asstr(get(at(nodes, i), "ref")), vnum(WHITE));
  }

  for (const auto& start : sortedkeys(edges)) {
    if (WHITE != static_cast<int>(asnum(get(colour, start)))) continue;

    std::vector<std::string> path{start};
    std::vector<std::pair<std::string, size_t>> stack{{start, 0}};
    set(colour, start, vnum(GREY));

    while (!stack.empty()) {
      auto& top = stack.back();
      V tos = get(edges, top.first);

      if (top.second >= len(tos)) {
        set(colour, top.first, vnum(BLACK));
        stack.pop_back();
        path.pop_back();
        continue;
      }

      const std::string next = asstr(at(tos, top.second));
      top.second++;
      int c = static_cast<int>(asnum(get(colour, next)));

      if (GREY == c) {
        /* Report the cycle itself, not the walk that found it. */
        V cycle = vlist();
        bool started = false;
        for (const auto& p : path) {
          if (!started && p == next) started = true;
          if (started) push(cycle, vstr(p));
        }
        push(cycle, vstr(next));
        return cycle;
      }
      if (BLACK == c) continue;

      set(colour, next, vnum(GREY));
      path.push_back(next);
      stack.push_back({next, 0});
    }
  }

  return nullptr;
}

void checkcycle(const V& nodes) {
  V cycle = dependencycycle(nodes);
  if (!cycle) return;
  std::string names;
  for (size_t i = 0; i < len(cycle); i++) {
    if (0 < i) names += " -> ";
    names += asstr(at(cycle, i));
  }
  fail("plugin_dependency_cycle", "requirements cycle: " + names,
       details1("cycle", cycle));
}

}  // namespace plugin
