// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/point.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Extension points (§6). See point.h for the closure representation. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "point.h"

/* The composition, walked by index rather than built as nested
 * closures. `chain_next` advances one step and calls the binding there;
 * the base runs when the bindings are exhausted. Identical to
 * `b1(b2(b3(base)))` and it needs no allocation per layer. */
struct Chain {
  Bound **bindings;
  size_t n;
  size_t i;
  HookFn base;
  void *basectx;
};

Value *chain_next(Chain *c, Value *arg) {
  if (NULL == c) return arg;
  if (c->i >= c->n) {
    return NULL == c->base ? arg : c->base(arg, c->basectx);
  }
  Bound *b = c->bindings[c->i];
  Chain rest;
  rest.bindings = c->bindings;
  rest.n = c->n;
  rest.i = c->i + 1;
  rest.base = c->base;
  rest.basectx = c->basectx;
  return b->chain(&rest, arg, b->ctx);
}

Value *point_call(Bound **bindings, size_t n, HookFn base, void *basectx,
                  Value *arg) {
  Chain c;
  c.bindings = bindings;
  c.n = n;
  c.i = 0;
  c.base = base;
  c.basectx = basectx;
  return chain_next(&c, arg);
}

Value *point_emit(Bound **bindings, size_t n, const char *mode, Value *arg,
                  Value **errors) {
  if (NULL != errors) *errors = vlist();

  if (0 == strcmp(mode, "bail")) {
    /* Stops at the first binding that RETURNS A VALUE — the "handled,
     * stop" case. A NULL DECLINES.
     *
     * JavaScript can tell null from undefined and almost nothing else
     * in the target set can — Go, Python, Ruby, PHP, Lua, Java and C#
     * each have exactly one way to say nothing, and C has one too.
     * Making the distinction load-bearing would cost every one of them
     * a wrapper type carried through the whole dispatch path, to
     * express a difference their plugin authors cannot write. §18's
     * budget settles it (§6.1). */
    for (size_t i = 0; i < n; i++) {
      Value *v = bindings[i]->hook(arg, bindings[i]->ctx);
      if (!visnull(v)) return v;
    }
    return NULL;
  }

  bool raising = 0 == strcmp(mode, "emit");
  for (size_t i = 0; i < n; i++) {
    if (raising) {
      /* `emit` raises synchronously; the collecting modes gather. */
      bindings[i]->hook(arg, bindings[i]->ctx);
      continue;
    }
    CatchFrame f;
    if (0 == PLUGIN_TRY(&f)) {
      bindings[i]->hook(arg, bindings[i]->ctx);
      PLUGIN_END(&f);
    }
    else if (NULL != errors) {
      Value *e = vmap();
      vset(e, "code", vstr(plugin_caught()->code));
      vset(e, "message", vstr(plugin_caught()->message));
      vpush(*errors, e);
    }
  }
  return NULL;
}

static int provrank(const void *pa, const void *pb) {
  Bound *a = *(Bound *const *)pa;
  Bound *b = *(Bound *const *)pb;
  /* HIGHEST band wins, unlike hook and chain. */
  if (a->band != b->band) return a->band > b->band ? -1 : 1;
  return strcmp(a->ref, b->ref);
}

Bound *point_provider(Bound **bindings, size_t n, bool exclusive,
                      Value **shadowed) {
  if (NULL != shadowed) *shadowed = vlist();
  if (0 == n) return NULL;

  Bound **ranked = (Bound **)arena_alloc(sizeof(Bound *) * n);
  memcpy(ranked, bindings, sizeof(Bound *) * n);

  if (exclusive && 1 < n) {
    const char **refs = (const char **)arena_alloc(sizeof(char *) * n);
    size_t sz = 96;
    for (size_t i = 0; i < n; i++) { refs[i] = bindings[i]->ref; sz += strlen(refs[i]) + 4; }
    /* Sorted, so the message names the same pair whatever order the
     * bindings arrived in. */
    for (size_t i = 0; i + 1 < n; i++) {
      for (size_t j = i + 1; j < n; j++) {
        if (0 < strcmp(refs[i], refs[j])) {
          const char *t = refs[i]; refs[i] = refs[j]; refs[j] = t;
        }
      }
    }
    Value *list = vlist();
    for (size_t i = 0; i < n; i++) vpush(list, vstr(refs[i]));
    char *text = (char *)arena_alloc(sz);
    size_t used = (size_t)snprintf(text, sz,
        "point is exclusive and has %zu bindings: ", n);
    for (size_t i = 0; i < n; i++) {
      used += (size_t)snprintf(text + used, sz - used, "%s%s",
                               0 < i ? ", " : "", refs[i]);
    }
    fail("plugin_point_exclusive", text, details1("refs", list));
  }

  if (1 < n) qsort(ranked, n, sizeof(Bound *), provrank);

  if (NULL != shadowed) {
    for (size_t i = 1; i < n; i++) vpush(*shadowed, vstr(ranked[i]->ref));
  }
  return ranked[0];
}
