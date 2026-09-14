// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/order.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Ordering (§7) — one rule, one place.
 *
 * sdkgen grew two special cases in `makeOptions` (`test`, then
 * `station`) and the third was not far off. This sort is the whole
 * replacement, and the tiers are in this order for a reason:
 *
 *   1 constraints   before/after edges, by ref or by name
 *   2 bands         integer, lower first, default 0
 *   3 declaration   ties break by `pos`
 *
 * CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both
 * are present. A band expresses a genuine cross-cutting layer; a
 * constraint expresses a relationship between two specific things; and
 * a band chosen by trial and error to fix an ordering bug is a bug
 * wearing a number. */

#include "order.hpp"

#include <algorithm>

#include "ref.hpp"

namespace plugin {

static double bandof(const V& b) {
  /* A NUMBER, not a numeric string. `order.band` accepting "1" was a
   * surviving mutation in more than one port: the corpus pins the type
   * because two ports disagreeing about whether "1" is a band is
   * exactly the divergence a shared corpus exists to remove. */
  V band = get(get(b, "order"), "band");
  return isnum(band) ? asnum(band) : 0.0;
}

static double posof(const V& b) {
  V p = get(b, "pos");
  return isnum(p) ? asnum(p) : 0.0;
}

/* Band first (lower runs first), then `pos` — the position the DOCUMENT
 * visibly states, not the order instances happened to load and not the
 * incarnation `seq`. */
struct Ready {
  V binding;
  size_t seq;
};

/* THE RANK IS TOTAL, and the third key is why. Band and pos can both
   tie — `declare` defaults `pos` to the registry size, so an unload
   followed by a fresh declare reuses a surviving instance's — and
   `std::sort` is not stable, so the topological order would differ from
   every other port's. The DECLARATION SEQUENCE (the index `order` fed
   them in) breaks the last tie, which is what the stable-sort ports get
   for free. */
static bool ranks(const Ready& x, const Ready& y) {
  double ab = bandof(x.binding), bb = bandof(y.binding);
  if (ab != bb) return ab < bb;
  double ap = posof(x.binding), bp = posof(y.binding);
  if (ap != bp) return ap < bp;
  return x.seq < y.seq;
}

/* Was a constraint actually declared? An ABSENT one and an EMPTY LIST
 * are both "no constraint"; only a non-empty spelling is an edge. */
static bool declared(const V& spec) {
  if (islist(spec)) return 0 < len(spec);
  if (isstr(spec)) return !asstr(spec).empty();
  return false;
}

/* Matching is by REF, or by NAME across all of that definition's
 * instances (§7) — which is the whole reason the two spellings exist. */
static std::vector<std::string> targets(const V& spec, const V& nodes) {
  std::vector<std::string> hit;
  size_t sn = islist(spec) ? len(spec) : 1;
  for (size_t si = 0; si < sn; si++) {
    V oneval = islist(spec) ? at(spec, si) : spec;
    if (!isstr(oneval)) continue;
    const std::string one = asstr(oneval);
    for (size_t i = 0; i < len(nodes); i++) {
      const std::string ref = asstr(get(at(nodes, i), "ref"));
      if (hit.end() != std::find(hit.begin(), hit.end(), ref)) continue;
      if (ref == one || refname(ref) == one) hit.push_back(ref);
    }
  }
  return hit;
}

/* A PIN IS NOT A CONSTRAINT (§7).
 *
 * Constraints and bands are negotiable by definition — they are what
 * plugins and documents say they want, and the sort's job is to satisfy
 * them all. A pin is the host stating a structural invariant of its own
 * architecture, which is a different kind of claim and must not lose a
 * tie to a document.
 *
 * So a pin PLACES the binding at the named end, and an ordering that
 * would move it away is `plugin_order_pinned` — rejected, not honoured
 * into a broken wrap. */
static V applypin(const V& order, const V& edges, const V& pin) {
  if (!ismap(pin)) return order;

  std::vector<std::string> out;
  for (size_t i = 0; i < len(order); i++) out.push_back(asstr(at(order, i)));

  /* SORTED, not insertion order. A pin map is data — it can arrive from
   * a host's own construction options in any order, and two names
   * pinned to the same end are order-sensitive. Sorted is the one order
   * every language agrees on, and `order/pin#two-names` pins it. */
  for (const auto& name : sortedkeys(pin)) {
    const std::string want = asstr(get(pin, name));
    size_t idx = out.size();
    for (size_t j = 0; j < out.size(); j++) {
      if (refname(out[j]) == name) { idx = j; break; }
    }
    if (out.size() == idx) continue;

    /* `first`/`outermost` is index 0; `last`/`innermost` is the end.
     * §6.2 makes the first chain binding outermost, which is why the
     * vocabulary is positional and why the two spellings pair this
     * way. */
    bool wantfirst = "first" == want || "outermost" == want;
    std::string ref = out[idx];
    out.erase(out.begin() + static_cast<long>(idx));
    if (wantfirst) out.insert(out.begin(), ref);
    else out.push_back(ref);
  }

  /* Now check that the placement did not break a constraint. This is
   * the half that makes a pin a rejection rather than an override: the
   * host wins on position, but it does not get to silently discard a
   * relationship a plugin declared. */
  V index = vmap();
  for (size_t i = 0; i < out.size(); i++) {
    set(index, out[i], vnum(static_cast<double>(i)));
  }
  for (const auto& from : sortedkeys(edges)) {
    V tos = get(edges, from);
    for (size_t j = 0; j < len(tos); j++) {
      const std::string to = asstr(at(tos, j));
      if (asnum(get(index, from)) > asnum(get(index, to))) {
        V d = vmap();
        set(d, "before", vstr(from));
        set(d, "after", vstr(to));
        fail("plugin_order_pinned",
             "a pin would move a binding an ordering constrains: " + from +
                 " must precede " + to,
             d);
      }
    }
  }

  V result = vlist();
  for (const auto& r : out) push(result, vstr(r));
  return result;
}

V resolveorder(const V& bindings, const V& pin) {
  const size_t n = len(bindings);

  V byref = vmap();
  for (size_t i = 0; i < n; i++) {
    set(byref, asstr(get(at(bindings, i), "ref")), at(bindings, i));
  }

  /* Constraints are edges. A constraint naming an ABSENT binding is
   * satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
   * load in a host with no test plugin. That is sdkgen's __after__
   * behaviour, kept. */
  V edges = vmap();
  for (size_t i = 0; i < n; i++) {
    set(edges, asstr(get(at(bindings, i), "ref")), vlist());
  }

  for (size_t i = 0; i < n; i++) {
    V b = at(bindings, i);
    const std::string bref = asstr(get(b, "ref"));
    V o = get(b, "order");
    V after = get(o, "after");
    V before = get(o, "before");
    if (declared(after)) {
      for (const auto& t : targets(after, bindings)) push(get(edges, t), vstr(bref));
    }
    if (declared(before)) {
      for (const auto& t : targets(before, bindings)) push(get(edges, bref), vstr(t));
    }
  }

  /* Stable topological sort. */
  V indeg = vmap();
  for (size_t i = 0; i < n; i++) {
    set(indeg, asstr(get(at(bindings, i), "ref")), vnum(0));
  }
  for (const auto& from : keys(edges)) {
    V tos = get(edges, from);
    for (size_t j = 0; j < len(tos); j++) {
      const std::string to = asstr(at(tos, j));
      set(indeg, to, vnum(asnum(get(indeg, to)) + 1));
    }
  }

  /* `seq` is the index the binding arrived at, and it never repeats: a
     binding enters `ready` exactly once, either up front or when its
     last edge clears. */
  std::vector<Ready> ready;
  size_t seq = 0;
  for (size_t i = 0; i < n; i++) {
    V b = at(bindings, i);
    if (0 == asnum(get(indeg, asstr(get(b, "ref"))))) ready.push_back({b, seq++});
  }

  std::vector<std::string> out;
  while (!ready.empty()) {
    std::sort(ready.begin(), ready.end(), ranks);
    V next = ready.front().binding;
    ready.erase(ready.begin());

    const std::string nref = asstr(get(next, "ref"));
    out.push_back(nref);
    V tos = get(edges, nref);
    for (size_t j = 0; j < len(tos); j++) {
      const std::string to = asstr(at(tos, j));
      double d = asnum(get(indeg, to)) - 1;
      set(indeg, to, vnum(d));
      if (0 == d) ready.push_back({get(byref, to), seq++});
    }
  }

  if (out.size() != n) {
    V stuck = vlist();
    std::string names;
    for (size_t i = 0; i < n; i++) {
      const std::string ref = asstr(get(at(bindings, i), "ref"));
      if (out.end() != std::find(out.begin(), out.end(), ref)) continue;
      if (0 < len(stuck)) names += " -> ";
      names += ref;
      push(stuck, vstr(ref));
    }
    fail("plugin_order_cycle", "before/after constraints cycle: " + names,
         details1("cycle", stuck));
  }

  V ordered = vlist();
  for (const auto& r : out) push(ordered, vstr(r));
  return applypin(ordered, edges, pin);
}

}  // namespace plugin
