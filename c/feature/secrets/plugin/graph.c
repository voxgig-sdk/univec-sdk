// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/graph.c)
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

#include <stdlib.h>
#include <string.h>

#include "graph.h"
#include "capability.h"
#include "ref.h"
#include "version.h"

static int bytewise(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static bool inset(Value *set, const char *ref) {
  return vhas(set, ref);
}

static Value *candidates(Value *byref, Value *name) {
  Value *out = vlist();
  /* A NODE SATISFIES ITS OWN REF (§11.1), and this is where the graph
   * learned it. Considering only declared capabilities made `resolve`
   * answer `absent` about a provider sitting right there and live —
   * §11.4's whole job is explaining the graph the runtime reconciles,
   * and it was explaining a different one. Canonical (§4 rule 5), and
   * tolerant, because a capability name need not be a well-formed ref. */
  const char *asref = visstr(name) ? tryref(vasstr(name)) : NULL;

  const char **refs;
  size_t n = vsortedkeys(byref, &refs);
  for (size_t i = 0; i < n; i++) {
    Value *node = vget(byref, refs[i]);
    Value *pos = vget(node, "pos");
    /* The ref match WINS OUTRIGHT for that node, as at runtime: one
     * candidate, not two, for a node both named `b` and providing `b` —
     * without the skip the blocked-chain explanation named it twice. */
    if (NULL != asref && 0 == strcmp(refs[i], asref)) {
      Value *prov = vmap();
      vset(prov, "name", name);
      Value *cand = vmap();
      vset(cand, "ref", vget(node, "ref"));
      vset(cand, "pos", visnum(pos) ? pos : vnum(0));
      vset(cand, "provides", prov);
      vpush(out, cand);
      continue;
    }
    Value *provides = vget(node, "provides");
    for (size_t j = 0; j < vlen(provides); j++) {
      Value *p = vat(provides, j);
      if (vsame(vget(p, "name"), name)) {
        Value *cand = vmap();
        vset(cand, "ref", vget(node, "ref"));
        vset(cand, "pos", visnum(pos) ? pos : vnum(0));
        vset(cand, "provides", p);
        vpush(out, cand);
      }
    }
  }
  return out;
}

static Value *blockedof(Value *node, Value *unmet, Value *why) {
  Value *out = vmap();
  vset(out, "ref", vget(node, "ref"));
  vset(out, "unmet", unmet);
  vset(out, "why", why);
  return out;
}

static Value *why1(const char *kind) {
  Value *w = vmap();
  vset(w, "kind", vstr(kind));
  return w;
}

/* The FIRST unmet requirement, with the most specific explanation
 * available. Order matters: "no provider at all" and "a provider at the
 * wrong version" are different problems and a reader must not have to
 * guess which they have. */
static Value *firstunmet(Value *node, Value *byref, Value *resolved) {
  Value *requires = vget(node, "requires");
  for (size_t ri = 0; ri < vlen(requires); ri++) {
    Value *req = vat(requires, ri);
    if (vtruthy(vget(req, "optional"))) continue;

    Value *name = vget(req, "name");
    Value *all = candidates(byref, name);
    if (0 == vlen(all)) {
      return blockedof(node, name, why1("absent"));
    }

    Value *ok = resolvecapability(req, all);
    if (0 < vlen(ok)) {
      /* A provider exists and matches — but if none of them is itself
       * resolved, this node is blocked BEHIND it, and the chain is the
       * useful answer rather than "unmet". */
      bool live = false;
      for (size_t i = 0; i < vlen(ok); i++) {
        if (inset(resolved, vasstr(vget(vat(ok, i), "ref")))) { live = true; break; }
      }
      if (live) continue;

      size_t n = vlen(ok);
      const char **chain = (const char **)arena_alloc(sizeof(char *) * (n + 1));
      for (size_t i = 0; i < n; i++) chain[i] = vasstr(vget(vat(ok, i), "ref"));
      if (1 < n) qsort((void *)chain, n, sizeof(char *), bytewise);
      Value *list = vlist();
      for (size_t i = 0; i < n; i++) vpush(list, vstr(chain[i]));
      Value *w = why1("blocked");
      vset(w, "chain", list);
      return blockedof(node, name, w);
    }

    /* Providers exist and none matched. Say which test failed. */
    Value *range = vget(req, "range");
    if (!visnull(range)) {
      Value *found = vlist();
      for (size_t i = 0; i < vlen(all); i++) {
        Value *prov = vget(vat(all, i), "provides");
        Value *version = vget(prov, "version");
        if (visnull(version) || !satisfiesq(version, range)) {
          vpush(found, visnull(version) ? vstr("(none)") : version);
        }
      }
      if (0 < vlen(found)) {
        size_t n = vlen(found);
        const char **vs = (const char **)arena_alloc(sizeof(char *) * (n + 1));
        for (size_t i = 0; i < n; i++) vs[i] = vasstr(vat(found, i));
        if (1 < n) qsort((void *)vs, n, sizeof(char *), bytewise);
        Value *sorted = vlist();
        for (size_t i = 0; i < n; i++) vpush(sorted, vstr(vs[i]));
        Value *w = why1("version");
        vset(w, "range", range);
        vset(w, "found", sorted);
        return blockedof(node, name, w);
      }
    }

    Value *match = vget(req, "match");
    if (!visnull(match)) {
      for (size_t i = 0; i < vlen(all); i++) {
        Value *prov = vget(vat(all, i), "provides");
        Value *attrs = vget(prov, "attrs");
        if (visnull(attrs)) attrs = vmap();
        const char **keys;
        size_t kn = vsortedkeys(match, &keys);
        for (size_t k = 0; k < kn; k++) {
          /* The same recursive partial match the selection applies, so
           * a nested requirement that FAILED the selection is also the
           * one the diagnosis names (§11.4). */
          if (!vhas(attrs, keys[k]) ||
              !capmatchvalue(vget(match, keys[k]), vget(attrs, keys[k]))) {
            Value *w = why1("match");
            vset(w, "failing", vstr(keys[k]));
            vset(w, "want", vget(match, keys[k]));
            Value *got = vget(attrs, keys[k]);
            vset(w, "found", visnull(got) ? vnull() : got);
            return blockedof(node, name, w);
          }
        }
      }
    }

    return blockedof(node, name, why1("absent"));
  }
  return NULL;
}

Value *resolvegraph(Value *nodes) {
  Value *byref = vmap();
  for (size_t i = 0; i < vlen(nodes); i++) {
    Value *n = vat(nodes, i);
    vset(byref, vasstr(vget(n, "ref")), n);
  }

  Value *resolved = vmap();

  /* Fixed point: a node resolves when every mandatory requirement is
   * met by an ALREADY-RESOLVED provider. Iterating to a fixed point is
   * what makes a provider that is itself blocked propagate, rather than
   * each node being judged against the raw registry. */
  bool moved = true;
  while (moved) {
    moved = false;
    for (size_t i = 0; i < vlen(nodes); i++) {
      Value *n = vat(nodes, i);
      const char *ref = vasstr(vget(n, "ref"));
      if (inset(resolved, ref)) continue;
      if (NULL == firstunmet(n, byref, resolved)) {
        vset(resolved, ref, vbool(true));
        moved = true;
      }
    }
  }

  Value *blocked = vmap();
  for (size_t i = 0; i < vlen(nodes); i++) {
    Value *n = vat(nodes, i);
    const char *ref = vasstr(vget(n, "ref"));
    if (inset(resolved, ref)) continue;
    Value *why = firstunmet(n, byref, resolved);
    if (NULL != why) vset(blocked, ref, why);
  }

  const char **keys;
  size_t rn = vsortedkeys(resolved, &keys);
  Value *resolvedlist = vlist();
  for (size_t i = 0; i < rn; i++) vpush(resolvedlist, vstr(keys[i]));

  size_t bn = vsortedkeys(blocked, &keys);
  Value *blockedlist = vlist();
  for (size_t i = 0; i < bn; i++) vpush(blockedlist, vget(blocked, keys[i]));

  Value *out = vmap();
  vset(out, "resolved", resolvedlist);
  vset(out, "blocked", blockedlist);
  return out;
}
