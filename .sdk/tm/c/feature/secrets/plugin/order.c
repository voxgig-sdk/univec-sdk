// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/order.c)
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "order.h"
#include "ref.h"

static double bandof(Value *b) {
  Value *o = vget(b, "order");
  Value *band = vget(o, "band");
  /* A NUMBER, not a numeric string. `order.band` accepting "1" was a
   * surviving mutation in more than one port: the corpus pins the type
   * because two ports disagreeing about whether "1" is a band is
   * exactly the divergence a shared corpus exists to remove. */
  return visnum(band) ? vasnum(band) : 0.0;
}

static double posof(Value *b) {
  Value *p = vget(b, "pos");
  return visnum(p) ? vasnum(p) : 0.0;
}

/* Band first (lower runs first), then `pos` — the position the DOCUMENT
 * visibly states, not the order instances happened to load and not the
 * incarnation `seq`. */
typedef struct Ready { Value *binding; size_t seq; } Ready;

/* THE RANK IS TOTAL, and the third key is why. Band and pos can both
 * tie — `declare` defaults `pos` to the registry size, so an unload
 * followed by a fresh declare reuses a surviving instance's — and
 * `qsort` is not stable, so on a libc that reorders equal elements the
 * topological order would differ from every other port's. The
 * DECLARATION SEQUENCE (the index `host_order` fed them in) breaks the
 * last tie, which is what the stable-sort ports get for free. */
static int rank(const void *pa, const void *pb) {
  const Ready *x = (const Ready *)pa;
  const Ready *y = (const Ready *)pb;
  double ab = bandof(x->binding), bb = bandof(y->binding);
  if (ab != bb) return ab < bb ? -1 : 1;
  double ap = posof(x->binding), bp = posof(y->binding);
  if (ap != bp) return ap < bp ? -1 : 1;
  if (x->seq != y->seq) return x->seq < y->seq ? -1 : 1;
  return 0;
}

/* Was a constraint actually declared? An ABSENT one and an EMPTY LIST
 * are both "no constraint"; only a non-empty spelling is an edge. */
static bool declared(Value *spec) {
  if (vislist(spec)) return 0 < vlen(spec);
  if (visstr(spec)) return '\0' != vasstr(spec)[0];
  return false;
}

/* Matching is by REF, or by NAME across all of that definition's
 * instances (§7) — which is the whole reason the two spellings exist. */
static Value *targets(Value *spec, Value *nodes) {
  Value *hit = vlist();
  Value *specs = vislist(spec) ? spec : NULL;
  size_t sn = NULL == specs ? 1 : vlen(specs);
  for (size_t si = 0; si < sn; si++) {
    Value *oneval = NULL == specs ? spec : vat(specs, si);
    if (!visstr(oneval)) continue;
    const char *one = vasstr(oneval);
    for (size_t i = 0; i < vlen(nodes); i++) {
      const char *ref = vasstr(vget(vat(nodes, i), "ref"));
      bool already = false;
      for (size_t j = 0; j < vlen(hit); j++) {
        if (0 == strcmp(vasstr(vat(hit, j)), ref)) { already = true; break; }
      }
      if (already) continue;
      if (0 == strcmp(ref, one)) { vpush(hit, vstr(ref)); continue; }
      if (0 == strcmp(refname(ref), one)) vpush(hit, vstr(ref));
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
static Value *applypin(Value *order, Value *edges, Value *pin) {
  if (!vismap(pin)) return order;

  Value *out = vlist();
  for (size_t i = 0; i < vlen(order); i++) vpush(out, vat(order, i));

  /* SORTED, not insertion order. A pin map is data — it can arrive from
   * a host's own construction options in any order, and two names
   * pinned to the same end are order-sensitive. Sorted is the one order
   * every language agrees on, and `order/pin#two-names` pins it. */
  const char **names;
  size_t pn = vsortedkeys(pin, &names);
  for (size_t i = 0; i < pn; i++) {
    Value *wantv = vget(pin, names[i]);
    const char *want = visstr(wantv) ? vasstr(wantv) : "";
    size_t idx = (size_t)-1;
    for (size_t j = 0; j < vlen(out); j++) {
      if (0 == strcmp(refname(vasstr(vat(out, j))), names[i])) { idx = j; break; }
    }
    if ((size_t)-1 == idx) continue;

    /* `first`/`outermost` is index 0; `last`/`innermost` is the end.
     * §6.2 makes the first chain binding outermost, which is why the
     * vocabulary is positional and why the two spellings pair this
     * way. */
    bool wantfirst = 0 == strcmp(want, "first") || 0 == strcmp(want, "outermost");
    Value *ref = vat(out, idx);
    Value *moved = vlist();
    if (wantfirst) vpush(moved, ref);
    for (size_t j = 0; j < vlen(out); j++) {
      if (j != idx) vpush(moved, vat(out, j));
    }
    if (!wantfirst) vpush(moved, ref);
    out = moved;
  }

  /* Now check that the placement did not break a constraint. This is
   * the half that makes a pin a rejection rather than an override: the
   * host wins on position, but it does not get to silently discard a
   * relationship a plugin declared. */
  Value *at = vmap();
  for (size_t i = 0; i < vlen(out); i++) {
    vset(at, vasstr(vat(out, i)), vnum((double)i));
  }
  const char **froms;
  size_t fn = vsortedkeys(edges, &froms);
  for (size_t i = 0; i < fn; i++) {
    Value *tos = vget(edges, froms[i]);
    for (size_t j = 0; j < vlen(tos); j++) {
      const char *to = vasstr(vat(tos, j));
      double a = vasnum(vget(at, froms[i]));
      double b = vasnum(vget(at, to));
      if (a > b) {
        size_t sz = strlen(froms[i]) + strlen(to) + 96;
        char *text = (char *)arena_alloc(sz);
        snprintf(text, sz,
                 "a pin would move a binding an ordering constrains: %s must precede %s",
                 froms[i], to);
        Value *d = vmap();
        vset(d, "before", vstr(froms[i]));
        vset(d, "after", vstr(to));
        fail("plugin_order_pinned", text, d);
      }
    }
  }

  return out;
}

Value *resolveorder(Value *bindings, Value *pin) {
  size_t n = vlen(bindings);

  Value *byref = vmap();
  for (size_t i = 0; i < n; i++) {
    Value *b = vat(bindings, i);
    vset(byref, vasstr(vget(b, "ref")), b);
  }

  /* Constraints are edges. A constraint naming an ABSENT binding is
   * satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
   * load in a host with no test plugin. That is sdkgen's __after__
   * behaviour, kept. */
  Value *edges = vmap();
  for (size_t i = 0; i < n; i++) {
    vset(edges, vasstr(vget(vat(bindings, i), "ref")), vlist());
  }

  for (size_t i = 0; i < n; i++) {
    Value *b = vat(bindings, i);
    const char *bref = vasstr(vget(b, "ref"));
    Value *o = vget(b, "order");
    Value *after = vget(o, "after");
    Value *before = vget(o, "before");
    if (declared(after)) {
      Value *ts = targets(after, bindings);
      for (size_t j = 0; j < vlen(ts); j++) {
        vpush(vget(edges, vasstr(vat(ts, j))), vstr(bref));
      }
    }
    if (declared(before)) {
      Value *ts = targets(before, bindings);
      for (size_t j = 0; j < vlen(ts); j++) {
        vpush(vget(edges, bref), vat(ts, j));
      }
    }
  }

  /* Stable topological sort. */
  Value *indeg = vmap();
  for (size_t i = 0; i < n; i++) {
    vset(indeg, vasstr(vget(vat(bindings, i), "ref")), vnum(0));
  }
  const char **froms;
  size_t fn = vkeys(edges, &froms);
  for (size_t i = 0; i < fn; i++) {
    Value *tos = vget(edges, froms[i]);
    for (size_t j = 0; j < vlen(tos); j++) {
      const char *to = vasstr(vat(tos, j));
      vset(indeg, to, vnum(vasnum(vget(indeg, to)) + 1));
    }
  }

  /* `seq` is the index the binding arrived at, and it never repeats:
   * a binding enters `ready` exactly once, either up front or when its
   * last edge clears. */
  Ready *ready = (Ready *)arena_alloc(sizeof(Ready) * (n + 1));
  size_t rn = 0;
  size_t seq = 0;
  for (size_t i = 0; i < n; i++) {
    Value *b = vat(bindings, i);
    if (0 == vasnum(vget(indeg, vasstr(vget(b, "ref"))))) {
      ready[rn].binding = b;
      ready[rn].seq = seq++;
      rn++;
    }
  }

  Value *out = vlist();
  while (0 < rn) {
    if (1 < rn) qsort(ready, rn, sizeof(Ready), rank);
    Value *next = ready[0].binding;
    for (size_t i = 1; i < rn; i++) ready[i - 1] = ready[i];
    rn--;

    const char *nref = vasstr(vget(next, "ref"));
    vpush(out, vstr(nref));
    Value *tos = vget(edges, nref);
    for (size_t j = 0; j < vlen(tos); j++) {
      const char *to = vasstr(vat(tos, j));
      double d = vasnum(vget(indeg, to)) - 1;
      vset(indeg, to, vnum(d));
      if (0 == d) {
        ready[rn].binding = vget(byref, to);
        ready[rn].seq = seq++;
        rn++;
      }
    }
  }

  if (vlen(out) != n) {
    Value *stuck = vlist();
    size_t sz = 64;
    for (size_t i = 0; i < n; i++) {
      const char *ref = vasstr(vget(vat(bindings, i), "ref"));
      bool placed = false;
      for (size_t j = 0; j < vlen(out); j++) {
        if (0 == strcmp(vasstr(vat(out, j)), ref)) { placed = true; break; }
      }
      if (!placed) { vpush(stuck, vstr(ref)); sz += strlen(ref) + 8; }
    }
    char *text = (char *)arena_alloc(sz);
    size_t used = (size_t)snprintf(text, sz, "before/after constraints cycle: ");
    for (size_t i = 0; i < vlen(stuck); i++) {
      used += (size_t)snprintf(text + used, sz - used, "%s%s",
                               0 < i ? " -> " : "", vasstr(vat(stuck, i)));
    }
    fail("plugin_order_cycle", text, details1("cycle", stuck));
  }

  return applypin(out, edges, pin);
}
