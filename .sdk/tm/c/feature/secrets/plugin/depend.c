// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/depend.c)
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "depend.h"
#include "ref.h"

/* A bare string is shorthand for `{name}`. */
Value *normrequire(Value *r) {
  if (visstr(r)) {
    Value *out = vmap();
    vset(out, "name", r);
    return out;
  }
  return vismap(r) ? r : vmap();
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
Value *requirements(Value *options) {
  Value *raw = vget(options, "requires");
  Value *marked = vget(options, "optional");
  Value *fallback = vget(options, "policy");

  Value *out = vlist();
  for (size_t i = 0; i < vlen(raw); i++) {
    Value *r = normrequire(vat(raw, i));
    Value *o = vmap();
    const char **keys;
    size_t n = vkeys(r, &keys);
    for (size_t j = 0; j < n; j++) vset(o, keys[j], vget(r, keys[j]));

    bool opt = vtruthy(vget(r, "optional"));
    if (!opt && vislist(marked)) {
      for (size_t j = 0; j < vlen(marked); j++) {
        if (vsame(vat(marked, j), vget(r, "name"))) { opt = true; break; }
      }
    }
    if (opt) vset(o, "optional", vbool(true));

    if (visnull(vget(o, "policy")) && !visnull(fallback)) {
      vset(o, "policy", fallback);
    }
    vpush(out, o);
  }
  return out;
}

/* Does losing this requirement's SELECTED provider restart the
 * consumer? The mandatory ones under `static`, and the `static`
 * optional ones — both make a capability change deactivate and
 * reactivate. `dynamic` never restarts. */
bool restartsonloss(Value *r) {
  Value *p = vget(r, "policy");
  const char *policy = visstr(p) ? vasstr(p) : "static";
  return 0 != strcmp(policy, "dynamic");
}

/* Does an unmet requirement keep the consumer out of `live`?
 *
 * CARDINALITY ALONE DECIDES THIS, NOT POLICY. `dynamic` is a statement
 * about surviving a SWAP, not about starting without the thing at all —
 * a mandatory-dynamic consumer still waits in `pending` for its first
 * provider. Conflating the two would let a plugin that declared it can
 * cope with replacement activate with nothing to call. */
bool gatesactivation(Value *r) {
  return true != vasbool(vget(r, "optional"));
}

/* Edges that can cause a restart, which is exactly the set a cycle must
 * be detected over (§11.3): the mandatory requirements AND THE `static`
 * OPTIONAL ONES, because both make a capability change deactivate and
 * reactivate the consumer — and a cycle of restarts does not settle.
 *
 * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
 * exclusion was for. An earlier draft of §11.3 excluded EVERY optional
 * edge and thereby admitted the non-terminating case it was trying to
 * permit. */
bool restartcausing(Value *r) {
  return gatesactivation(r) || restartsonloss(r);
}

static int bytewise(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static bool listhas(Value *l, const char *s) {
  for (size_t i = 0; i < vlen(l); i++) {
    if (0 == strcmp(vasstr(vat(l, i)), s)) return true;
  }
  return false;
}

Value *dependencycycle(Value *nodes) {
  /* TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
   * matched differently — a capability by its exact name, a ref through
   * the canonical spelling (§4 rule 5) — and one map keyed by both can
   * only do one of them. Keyed by both and looked up raw, a cycle
   * spelled `a$`/`b$` finds no providers and EVADES the load-time check
   * that exists to catch a non-terminating reconcile. */
  Value *bycap = vmap();
  Value *isref = vmap();
  for (size_t i = 0; i < vlen(nodes); i++) {
    Value *n = vat(nodes, i);
    const char *nref = vasstr(vget(n, "ref"));
    vset(isref, nref, vbool(true));
    Value *provides = vget(n, "provides");
    for (size_t j = 0; j < vlen(provides); j++) {
      const char *cap = vasstr(vat(provides, j));
      Value *l = vget(bycap, cap);
      if (visnull(l)) { l = vlist(); vset(bycap, cap, l); }
      vpush(l, vstr(nref));
    }
  }

  Value *edges = vmap();
  for (size_t i = 0; i < vlen(nodes); i++) {
    Value *n = vat(nodes, i);
    const char *nref = vasstr(vget(n, "ref"));
    Value *out = vlist();
    Value *reqs = vget(n, "requires");
    for (size_t j = 0; j < vlen(reqs); j++) {
      Value *r = vat(reqs, j);
      if (!restartcausing(r)) continue;
      const char *rname = visstr(vget(r, "name")) ? vasstr(vget(r, "name")) : "";
      Value *from = vlist();
      Value *caps = vget(bycap, rname);
      for (size_t k = 0; k < vlen(caps); k++) vpush(from, vat(caps, k));
      /* A node satisfies its own name AS A REF (§11.1), canonically —
       * exactly what `providersof` does at runtime, so the load-time
       * graph and the running one agree about what an edge is. */
      const char *asref = tryref(rname);
      if (NULL != asref && vhas(isref, asref) && !listhas(from, asref)) {
        vpush(from, vstr(asref));
      }
      for (size_t k = 0; k < vlen(from); k++) {
        const char *p = vasstr(vat(from, k));
        if (0 != strcmp(p, nref) && !listhas(out, p)) vpush(out, vstr(p));
      }
    }
    size_t on = vlen(out);
    const char **sorted = (const char **)arena_alloc(sizeof(char *) * (on + 1));
    for (size_t k = 0; k < on; k++) sorted[k] = vasstr(vat(out, k));
    if (1 < on) qsort((void *)sorted, on, sizeof(char *), bytewise);
    Value *sortedlist = vlist();
    for (size_t k = 0; k < on; k++) vpush(sortedlist, vstr(sorted[k]));
    vset(edges, nref, sortedlist);
  }

  /* Iterative DFS with an explicit stack: twenty ports, and several of
   * them have no recursion budget worth relying on. */
  enum { WHITE = 0, GREY = 1, BLACK = 2 };
  Value *colour = vmap();
  for (size_t i = 0; i < vlen(nodes); i++) {
    vset(colour, vasstr(vget(vat(nodes, i), "ref")), vnum(WHITE));
  }

  const char **starts;
  size_t sn = vsortedkeys(edges, &starts);
  for (size_t si = 0; si < sn; si++) {
    if (WHITE != (int)vasnum(vget(colour, starts[si]))) continue;

    Value *path = vlist();
    /* stack of {ref, i} */
    Value *stack = vlist();
    Value *frame = vmap();
    vset(frame, "ref", vstr(starts[si]));
    vset(frame, "i", vnum(0));
    vpush(stack, frame);
    vset(colour, starts[si], vnum(GREY));
    vpush(path, vstr(starts[si]));

    while (0 < vlen(stack)) {
      Value *top = vat(stack, vlen(stack) - 1);
      const char *tref = vasstr(vget(top, "ref"));
      size_t idx = (size_t)vasnum(vget(top, "i"));
      Value *tos = vget(edges, tref);

      if (idx >= vlen(tos)) {
        vset(colour, tref, vnum(BLACK));
        Value *popped = vlist();
        for (size_t k = 0; k + 1 < vlen(stack); k++) vpush(popped, vat(stack, k));
        stack = popped;
        Value *shorter = vlist();
        for (size_t k = 0; k + 1 < vlen(path); k++) vpush(shorter, vat(path, k));
        path = shorter;
        continue;
      }

      vset(top, "i", vnum((double)(idx + 1)));
      const char *next = vasstr(vat(tos, idx));
      int c = (int)vasnum(vget(colour, next));

      if (GREY == c) {
        /* Report the cycle itself, not the walk that found it. */
        Value *cycle = vlist();
        bool started = false;
        for (size_t k = 0; k < vlen(path); k++) {
          if (!started && 0 == strcmp(vasstr(vat(path, k)), next)) started = true;
          if (started) vpush(cycle, vat(path, k));
        }
        vpush(cycle, vstr(next));
        return cycle;
      }
      if (BLACK == c) continue;

      vset(colour, next, vnum(GREY));
      vpush(path, vstr(next));
      Value *nf = vmap();
      vset(nf, "ref", vstr(next));
      vset(nf, "i", vnum(0));
      vpush(stack, nf);
    }
  }

  return NULL;
}

void checkcycle(Value *nodes) {
  Value *cycle = dependencycycle(nodes);
  if (NULL == cycle) return;
  size_t sz = 64;
  for (size_t i = 0; i < vlen(cycle); i++) sz += strlen(vasstr(vat(cycle, i))) + 6;
  char *text = (char *)arena_alloc(sz);
  size_t used = (size_t)snprintf(text, sz, "requirements cycle: ");
  for (size_t i = 0; i < vlen(cycle); i++) {
    used += (size_t)snprintf(text + used, sz - used, "%s%s",
                             0 < i ? " -> " : "", vasstr(vat(cycle, i)));
  }
  fail("plugin_dependency_cycle", text, details1("cycle", cycle));
}
