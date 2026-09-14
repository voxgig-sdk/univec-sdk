// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/host.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The host: the lifecycle state machine (§5), extension points (§6),
 * and resource capture (§8). See host.h for the two rules that shape
 * every function here. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "host.h"
#include "capability.h"
#include "config.h"
#include "depend.h"
#include "export.h"
#include "graph.h"
#include "order.h"
#include "ref.h"

typedef struct ScopeEntry {
  ReleaseFn fn;
  void *ctx;
  bool done;
  /* `acquire` and `release` both count toward `open`; a nested host's
   * teardown does NOT — a teardown is not an acquisition, and the inner
   * host keeps its own counter (`nest/open`). */
  bool counts;
} ScopeEntry;

struct Inst {
  const char *ref;
  Definition *def;
  const char *status;
  double pos;
  double seq;
  Value *options;
  Value *state;
  Value *order;
  /* §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider ref
   * this instance's activation actually selected, per requirement name.
   * Recomputing the best candidate on every question silently re-points
   * a live consumer at any better-ranked newcomer, and then losing the
   * provider it was really using does not restart it. */
  Value *selected;
  /* §9.6's `active: false`. THE BAR OUTLIVES THE APPLY THAT SET IT: a
   * flag consulted only while `apply` ran let a later direct `ready`
   * bring the instance live, which is the config switch it exists to be
   * silently ignored. */
  bool barred;
  Value *unmet;
  ScopeEntry **scope;
  size_t nscope;
  size_t capscope;
  /* Declared in `define`, inserted only when activation SUCCEEDS
   * (§8.1). Holding them until then is what makes a failed activate
   * leave nothing behind. */
  Bound **bindings;
  size_t nbindings;
  size_t capbindings;
  Host *inner;
  /* Declared in `define`, and VISIBLE while merely `loaded` (§11): they
   * are data, and hiding them would make the loaded state useless for
   * introspection. */
  Value *exports;
  Value *provides;
  Host *owner;
  struct Inst *next;
};

struct Host {
  Catalog *catalog;
  Value *reserved;
  Value *keys;
  Value *defaults;
  Value *profile;
  Value *points;
  HookFn *basefns;
  Value *basepoints;
  const char *dependency;
  /* Set for the duration of a bulk teardown, so `held` knows this is a
   * coordinated operation rather than an ad-hoc deactivation. */
  bool coordinated;

  Inst *first;
  Value *log;
  Value *events;
  double seqn;
  double open;
  bool intransition;
  /* WHICH callback is running, not merely that one is. §8.1 puts
   * resource capture in `activate` and §8.3 says `release` outside
   * `activate` is `plugin_release_scope` — and a boolean alone cannot
   * tell `activate` from `define`, so it admitted an acquire in
   * `define` whose scope `unload` would never unwind. */
  const char *phase;
};

/* ------------------------------------------------------------------ */
/* registry helpers                                                    */
/* ------------------------------------------------------------------ */

static int bytewise(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* Every instance ref, SORTED — the deterministic walk §4 rule 4
 * requires in a language whose containers have no inherent order. */
static size_t sortedrefs(Host *h, const char ***out) {
  size_t n = 0;
  for (Inst *e = h->first; NULL != e; e = e->next) n++;
  const char **refs = (const char **)arena_alloc(sizeof(char *) * (n + 1));
  size_t i = 0;
  for (Inst *e = h->first; NULL != e; e = e->next) refs[i++] = e->ref;
  if (1 < n) qsort((void *)refs, n, sizeof(char *), bytewise);
  *out = refs;
  return n;
}

static Inst *findinst(Host *h, const char *ref) {
  for (Inst *e = h->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->ref, ref)) return e;
  }
  return NULL;
}

static void removeinst(Host *h, Inst *target) {
  Inst *prev = NULL;
  for (Inst *e = h->first; NULL != e; e = e->next) {
    if (e == target) {
      if (NULL == prev) h->first = e->next;
      else prev->next = e->next;
      return;
    }
    prev = e;
  }
}

static size_t instcount(Host *h) {
  size_t n = 0;
  for (Inst *e = h->first; NULL != e; e = e->next) n++;
  return n;
}

Catalog *host_catalog(Host *h) { return h->catalog; }
void host_define(Host *h, Definition *def) { catalog_add(h->catalog, def); }

Host *makehost(HostOptions *opts) {
  Host *h = (Host *)arena_alloc(sizeof(Host));
  h->catalog = (NULL != opts && NULL != opts->catalog) ? opts->catalog : makecatalog();
  h->reserved = (NULL != opts) ? opts->reserved : NULL;
  h->keys = (NULL != opts) ? opts->keys : NULL;
  h->defaults = (NULL != opts) ? opts->defaults : NULL;
  h->profile = (NULL != opts) ? opts->profile : NULL;
  h->points = (NULL != opts && vismap(opts->points)) ? opts->points : vmap();
  h->basefns = (NULL != opts) ? opts->basefns : NULL;
  h->basepoints = (NULL != opts) ? opts->basepoints : NULL;
  h->dependency = (NULL != opts && NULL != opts->dependency) ? opts->dependency : "restart";
  h->coordinated = false;
  h->first = NULL;
  h->log = vlist();
  h->events = vlist();
  h->seqn = 0;
  h->open = 0;
  h->intransition = false;
  h->phase = NULL;
  return h;
}

/* ------------------------------------------------------------------ */
/* observation                                                         */
/* ------------------------------------------------------------------ */

Value *host_list(Host *h) {
  Value *out = vmap();
  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    vset(out, refs[i], vstr(findinst(h, refs[i])->status));
  }
  return out;
}

Inst *host_instance(Host *h, const char *ref) {
  /* The VALIDATING canonicalizer, not the forgiving one: a lookup with
   * a malformed ref is `plugin_bad_name`, not a miss
   * (`declare/lookup#malformed`). Rust and swift both wrote this with
   * `canon` and failed that entry. */
  return findinst(h, canonref(vstr(ref)));
}

Inst *inst_of(Host *h, const char *ref) { return host_instance(h, ref); }

Value *host_observable(Host *h, Value *result, bool hasresult) {
  Value *out = vmap();
  vset(out, "status", host_list(h));
  vset(out, "open", vnum(h->open));
  Value *log = vlist();
  for (size_t i = 0; i < vlen(h->log); i++) vpush(log, vat(h->log, i));
  vset(out, "log", log);
  vset(out, "result", (!hasresult || NULL == result) ? vnull() : result);
  return out;
}

/* A COPY, not the live list: the canonical is `trace: () => events.slice()`, and `observable` already copies the log. Returning the live list lets a caller append to or delete from the host's own event record — application observation code fabricating or erasing lifecycle history. */
Value *host_trace(Host *h) {
  Value *out = vlist();
  for (size_t i = 0; i < vlen(h->events); i++) vpush(out, vat(h->events, i));
  return out;
}

Value *inst_status(Inst *i) { return vstr(i->status); }
double inst_seq(Inst *i) { return i->seq; }
double inst_pos(Inst *i) { return i->pos; }
Host *inst_inner(Inst *i) { return i->inner; }
const char *inst_ref(Inst *i) { return i->ref; }
const char *inst_name(Inst *i) { return refname(i->ref); }
const char *inst_tag(Inst *i) {
  const char *cut = strchr(i->ref, '$');
  return NULL == cut ? "" : cut + 1;
}
Value *inst_options(Inst *i) { return i->options; }
Value *inst_state(Inst *i) { return i->state; }
Host *inst_host(Inst *i) { return i->owner; }

/* ------------------------------------------------------------------ */
/* guards                                                              */
/* ------------------------------------------------------------------ */

static void guard(Host *h) {
  if (h->intransition) {
    fail("plugin_reentrant",
         "transition attempted from inside a lifecycle callback", NULL);
  }
}

static Inst *need(Host *h, const char *ref) {
  const char *r = canonref(vstr(ref));
  Inst *e = findinst(h, r);
  if (NULL == e) {
    size_t sz = strlen(r) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "no such instance: %s", r);
    fail("plugin_not_loaded", text, details1("ref", vstr(r)));
  }
  return e;
}

static void checkreserved(Host *h, const char *ref) {
  if (!vislist(h->reserved) || 0 == vlen(h->reserved)) return;
  const char *name = refname(ref);
  for (size_t i = 0; i < vlen(h->reserved); i++) {
    Value *r = vat(h->reserved, i);
    if (visstr(r) && 0 == strcmp(vasstr(r), name)) {
      size_t sz = strlen(ref) + 48;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "ref is reserved by the host: %s", ref);
      fail("plugin_ref_reserved", text, details1("ref", vstr(ref)));
    }
  }
}

/* ------------------------------------------------------------------ */
/* scope                                                               */
/* ------------------------------------------------------------------ */

static void pushscope(Inst *e, ReleaseFn fn, void *ctx, bool counts) {
  if (e->nscope == e->capscope) {
    size_t cap = 0 == e->capscope ? 8 : e->capscope * 2;
    ScopeEntry **grown = (ScopeEntry **)arena_alloc(sizeof(ScopeEntry *) * cap);
    for (size_t i = 0; i < e->nscope; i++) grown[i] = e->scope[i];
    e->scope = grown;
    e->capscope = cap;
  }
  ScopeEntry *s = (ScopeEntry *)arena_alloc(sizeof(ScopeEntry));
  s->fn = fn;
  s->ctx = ctx;
  s->done = false;
  s->counts = counts;
  e->scope[e->nscope++] = s;
}

/* A selection belongs to ONE activation (§11.4). Leaving `live` by any
 * door drops it, so the next activation ranks afresh — keeping it would
 * make a consumer prefer a provider it never actually ran against.
 *
 * Returns the errors the scope raised. §8.3: "A failing release does
 * not stop the rest. Every entry runs, in reverse order, whatever any
 * of them does; the errors are collected and raised as one
 * `plugin_release_failed`." */
static Value *unwind(Host *h, Inst *e) {
  e->selected = vmap();
  Value *errors = vlist();
  for (size_t k = e->nscope; 0 < k; k--) {
    ScopeEntry *s = e->scope[k - 1];
    if (s->done) continue;
    s->done = true;
    if (s->counts) h->open -= 1;
    if (NULL == s->fn) continue;
    CatchFrame f;
    if (0 == PLUGIN_TRY(&f)) {
      s->fn(s->ctx);
      PLUGIN_END(&f);
    }
    else {
      vpush(errors, vstr(plugin_caught()->message));
    }
  }
  e->nscope = 0;
  return errors;
}

/* §8.3: "A failed release ends the instance in `failed`, exactly as a
 * failed callback does (§5.2) — a release that raised may have leaked,
 * and an instance that may be holding resources it cannot account for
 * must not be reactivated." */
static void releasecheck(Inst *e, Value *errors) {
  if (0 == vlen(errors)) return;
  e->status = "failed";
  size_t sz = strlen(e->ref) + 64;
  for (size_t i = 0; i < vlen(errors); i++) sz += strlen(vasstr(vat(errors, i))) + 4;
  char *text = (char *)arena_alloc(sz);
  size_t used = (size_t)snprintf(text, sz, "release failed for %s: ", e->ref);
  for (size_t i = 0; i < vlen(errors); i++) {
    used += (size_t)snprintf(text + used, sz - used, "%s%s",
                             0 < i ? "; " : "", vasstr(vat(errors, i)));
  }
  Value *d = vmap();
  vset(d, "ref", vstr(e->ref));
  vset(d, "cause", errors);
  fail("plugin_release_failed", text, d);
}

/* ------------------------------------------------------------------ */
/* the instance api                                                    */
/* ------------------------------------------------------------------ */

AcquireHandle *inst_acquire(Inst *e) {
  /* §8.1: resources are "acquired during `activate` — the scope's
   * actual job". */
  if (NULL == e->owner->phase || 0 != strcmp(e->owner->phase, "activate")) {
    fail("plugin_release_scope", "acquire called outside activate", NULL);
  }
  pushscope(e, NULL, NULL, true);
  e->owner->open += 1;
  return e->scope[e->nscope - 1];
}

/* Hand a resource back before teardown. Idempotent, and the scope keeps
 * the entry: unwinding it again must be a no-op, or releasing early
 * would make teardown wrong. */
void inst_giveback(Inst *e, AcquireHandle *handle) {
  if (NULL == handle || handle->done) return;
  handle->done = true;
  if (handle->counts) e->owner->open -= 1;
}

void inst_release(Inst *e, ReleaseFn fn, void *ctx) {
  /* §8.3: "`inst.release` outside `activate` is `plugin_release_scope`".
   * Being in a transition is true in `define` too, and a scope entry
   * registered there is never unwound — `unload` on a merely `loaded`
   * instance does not unwind, because a loaded instance is not supposed
   * to hold anything. */
  if (NULL == e->owner->phase || 0 != strcmp(e->owner->phase, "activate")) {
    fail("plugin_release_scope", "release called outside activate", NULL);
  }
  /* SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
   * resources CURRENTLY HELD, so an entry that is registered and then
   * unwound must leave the count where it found it. Incrementing on
   * registration and never decrementing made every `release` a
   * permanent leak in the counter. */
  pushscope(e, fn, ctx, true);
  e->owner->open += 1;
}

void inst_bind(Inst *e, const char *point, HookFn hook, ChainFn chain,
               void *ctx, Value *band) {
  Host *h = e->owner;
  /* §12's `plugin_bind_scope`: "binding declared outside `define`". §8.1
   * puts binding declaration in `define` and insertion at a SUCCESSFUL
   * activate, and the guard was the half that never got written — so a
   * binding added from `activate` went live without being part of the
   * loaded definition, and a deactivate/activate cycle appended it
   * again. The code was in the table before anything raised it. */
  if (NULL == h->phase || 0 != strcmp(h->phase, "define")) {
    size_t sz = strlen(point) + 48;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "bind called outside define: %s", point);
    Value *d = vmap();
    vset(d, "ref", vstr(e->ref));
    vset(d, "point", vstr(point));
    fail("plugin_bind_scope", text, d);
  }
  if (!vhas(h->points, point)) {
    size_t sz = strlen(point) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "no such point: %s", point);
    fail("plugin_point_unknown", text, details1("point", vstr(point)));
  }

  if (e->nbindings == e->capbindings) {
    size_t cap = 0 == e->capbindings ? 8 : e->capbindings * 2;
    Bound **grown = (Bound **)arena_alloc(sizeof(Bound *) * cap);
    for (size_t i = 0; i < e->nbindings; i++) grown[i] = e->bindings[i];
    e->bindings = grown;
    e->capbindings = cap;
  }
  Bound *b = (Bound *)arena_alloc(sizeof(Bound));
  b->ref = e->ref;
  b->point = arena_strdup(point);
  b->band = visnum(band) ? vasnum(band) : 0.0;
  b->hook = hook;
  b->chain = chain;
  b->ctx = ctx;
  e->bindings[e->nbindings++] = b;
}

void inst_export(Inst *e, const char *key, Value *value) {
  vset(e->exports, key, value);
}

void inst_provides(Inst *e, Value *p) { vpush(e->provides, p); }

/* The scope entry carries the inner host as its context — C's stand-in
 * for the closure every other port writes here. */
static void closeinner(void *ctx) { host_close((Host *)ctx); }

Host *inst_nest(Inst *e, HostOptions *opts) {
  Host *h = e->owner;
  if (!h->intransition) {
    fail("plugin_release_scope", "nest called outside a lifecycle callback", NULL);
  }
  /* AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
   * INNER ONE'S LIFETIME. Registering the teardown in the instance
   * scope is what makes that true rather than aspirational: the inner
   * host closes when the outer instance deactivates, in the same
   * reverse unwind as every other resource.
   *
   * It does NOT count toward `open` — a teardown is not an acquisition
   * (`nest/open`). */
  Host *inner = makehost(opts);
  pushscope(e, closeinner, inner, false);
  e->inner = inner;
  return inner;
}

/* ------------------------------------------------------------------ */
/* running a callback                                                  */
/* ------------------------------------------------------------------ */

static void run(Host *h, Inst *e, const char *at) {
  LifecycleFn fn = definition_callback(e->def, at);

  size_t sz = strlen(e->ref) + strlen(at) + 2;
  char *entry = (char *)arena_alloc(sz);
  snprintf(entry, sz, "%s:%s", e->ref, at);
  vpush(h->log, vstr(entry));

  Value *ev = vmap();
  vset(ev, "ref", vstr(e->ref));
  vset(ev, "event", vstr(at));
  vset(ev, "seq", vnum(e->seq));
  vset(ev, "status", vstr(e->status));
  vpush(h->events, ev);

  if (NULL == fn) return;

  h->intransition = true;
  h->phase = at;

  CatchFrame f;
  if (0 == PLUGIN_TRY(&f)) {
    fn(e);
    PLUGIN_END(&f);
    h->intransition = false;
    h->phase = NULL;
    return;
  }

  h->intransition = false;
  h->phase = NULL;

  /* §12: `plugin_define_failed` and its three siblings are "a callback
   * raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A CODE
   * KEEPS IT — the code is the error's identity, and a plugin that
   * raised `store_unreachable` must not have it rewritten. Only a
   * code-less error is wrapped, which is the ordinary case for a
   * callback that let a library error escape. */
  if (NULL != plugin_caught()->code && '\0' != plugin_caught()->code[0] &&
      0 != strcmp(plugin_caught()->code, "plugin_bare")) {
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }
  size_t tsz = strlen(e->ref) + strlen(at) + strlen(plugin_caught()->text) + 48;
  char *text = (char *)arena_alloc(tsz);
  snprintf(text, tsz, "%s raised in %s: %s", e->ref, at, plugin_caught()->text);
  char *code = (char *)arena_alloc(strlen(at) + 24);
  snprintf(code, strlen(at) + 24, "plugin_%s_failed", at);
  Value *d = vmap();
  vset(d, "ref", vstr(e->ref));
  vset(d, "cause", vstr(plugin_caught()->text));
  fail(code, text, d);
}

/* ------------------------------------------------------------------ */
/* requirements and providers                                          */
/* ------------------------------------------------------------------ */

static Value *providersof(Host *h, Value *req) {
  Value *cands = vlist();
  /* ASK WHETHER THE NAME IS A REF, do not assume it. A requirement name
   * is a CAPABILITY name first (§11.1) and capability names are
   * free-form, so `2fa` and `my cap` are legal ones that no ref could
   * be called — and `canonref` RAISES on those, which made a perfectly
   * legal document kill the host right here. */
  Value *rname = vget(req, "name");
  const char *asref = visstr(rname) ? tryref(vasstr(rname)) : NULL;

  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    Inst *t = findinst(h, refs[i]);
    if (0 != strcmp(t->status, "live")) continue;
    /* A ref satisfies directly. */
    if (NULL != asref && 0 == strcmp(refs[i], asref)) {
      Value *prov = vmap();
      vset(prov, "name", rname);
      Value *c = vmap();
      vset(c, "ref", vstr(refs[i]));
      vset(c, "pos", vnum(t->pos));
      vset(c, "provides", prov);
      vpush(cands, c);
      continue;
    }
    for (size_t j = 0; j < vlen(t->provides); j++) {
      Value *p = vat(t->provides, j);
      if (vsame(vget(p, "name"), rname)) {
        Value *c = vmap();
        vset(c, "ref", vstr(refs[i]));
        vset(c, "pos", vnum(t->pos));
        vset(c, "provides", p);
        vpush(cands, c);
      }
    }
  }
  return resolvecapability(req, cands);
}

static Value *unmetof(Host *h, Inst *e) {
  Value *out = vlist();
  Value *reqs = requirements(e->options);
  for (size_t i = 0; i < vlen(reqs); i++) {
    Value *r = vat(reqs, i);
    if (!gatesactivation(r)) continue;
    if (0 == vlen(providersof(h, r))) vpush(out, vget(r, "name"));
  }
  return out;
}

/* §11.4's always-reluctant selection, and the ONE place a provider is
 * chosen for a live instance. "A satisfied requirement is not re-bound
 * while it stays satisfied" is a statement about a REMEMBERED choice.
 *
 * `remember` is false for the questions asked ABOUT an instance rather
 * than BY it — introspection must not create a binding. */
static const char *chosen(Host *h, Inst *e, Value *req, bool remember) {
  Value *cands = providersof(h, req);
  if (0 == vlen(cands)) return NULL;
  const char *name = vasstr(vget(req, "name"));
  Value *heldv = vget(e->selected, name);
  if (visstr(heldv)) {
    for (size_t i = 0; i < vlen(cands); i++) {
      if (0 == strcmp(vasstr(vget(vat(cands, i), "ref")), vasstr(heldv))) {
        return vasstr(heldv);
      }
    }
  }
  const char *first = vasstr(vget(vat(cands, 0), "ref"));
  if (remember) vset(e->selected, name, vstr(first));
  return first;
}

/* The instance currently SELECTED for each of this one's
 * restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
 * capability (§11.1): the selected one going away restarts a `static`
 * consumer even though a survivor is available. */
static Value *boundproviders(Host *h, Inst *e) {
  Value *out = vlist();
  Value *reqs = requirements(e->options);
  for (size_t i = 0; i < vlen(reqs); i++) {
    Value *r = vat(reqs, i);
    if (!restartsonloss(r)) continue;
    const char *ref = chosen(h, e, r, false);
    if (NULL == ref) continue;
    bool dup = false;
    for (size_t j = 0; j < vlen(out); j++) {
      if (0 == strcmp(vasstr(vat(out, j)), ref)) { dup = true; break; }
    }
    if (!dup) vpush(out, vstr(ref));
  }
  return out;
}

static Value *consumersof(Host *h, const char *ref) {
  Value *out = vlist();
  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    if (0 == strcmp(refs[i], ref)) continue;
    Inst *c = findinst(h, refs[i]);
    if (0 != strcmp(c->status, "live")) continue;
    Value *bp = boundproviders(h, c);
    for (size_t j = 0; j < vlen(bp); j++) {
      if (0 == strcmp(vasstr(vat(bp, j)), ref)) { vpush(out, vstr(refs[i])); break; }
    }
  }
  return out;
}

/* §11.3's `hold` asks a DIFFERENT question from the cascade.
 *
 * The cascade wants the edges that RESTART — mandatory-static and
 * optional-static. `hold` says "deactivating a REQUIRED instance is
 * `plugin_dependency_held`", and `required` is CARDINALITY:
 * `gatesactivation`, not `restartsonloss`. The two sets differ in both
 * directions and each difference was a real bug. */
static Value *holdersof(Host *h, const char *ref) {
  Value *out = vlist();
  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    if (0 == strcmp(refs[i], ref)) continue;
    Inst *c = findinst(h, refs[i]);
    if (0 != strcmp(c->status, "live")) continue;
    Value *reqs = requirements(c->options);
    for (size_t j = 0; j < vlen(reqs); j++) {
      Value *req = vat(reqs, j);
      if (!gatesactivation(req)) continue;
      const char *sel = chosen(h, c, req, false);
      if (NULL != sel && 0 == strcmp(sel, ref)) { vpush(out, vstr(refs[i])); break; }
    }
  }
  return out;
}

/* The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
 * TEARDOWN. In a bulk operation that is removing the holders too, it is
 * suspended — otherwise `close()` under `hold` would raise on the first
 * provider it reached whenever a document happened to list a consumer
 * after it, which is the policy refusing the one teardown it has no
 * reason to object to. */
static void held(Host *h, Inst *e) {
  if (0 != strcmp(h->dependency, "hold")) return;
  if (h->coordinated) return;
  Value *holders = holdersof(h, e->ref);
  if (0 == vlen(holders)) return;
  size_t sz = strlen(e->ref) + 64;
  char *text = (char *)arena_alloc(sz);
  snprintf(text, sz, "instance is required by live consumers: %s", e->ref);
  Value *d = vmap();
  vset(d, "ref", vstr(e->ref));
  vset(d, "holders", holders);
  fail("plugin_dependency_held", text, d);
}

/* The requirement graph as plain data, for the pure detector. */
static Value *graphnodes(Host *h) {
  Value *out = vlist();
  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    Inst *e = findinst(h, refs[i]);
    Value *provides = vlist();
    for (size_t j = 0; j < vlen(e->provides); j++) {
      vpush(provides, vget(vat(e->provides, j), "name"));
    }
    Value *node = vmap();
    vset(node, "ref", vstr(refs[i]));
    vset(node, "provides", provides);
    vset(node, "requires", requirements(e->options));
    vpush(out, node);
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* ordering and points                                                 */
/* ------------------------------------------------------------------ */

Value *host_order(Host *h, const char *point) {
  /* Sorted by declaration SEQUENCE, which is what makes the §7 sort's
   * fall-through deterministic in a language whose containers have no
   * insertion order. §7 breaks ties by `pos`; two instances CAN share
   * one — `declare` defaults `pos` to the registry size, so an unload
   * followed by a fresh declare reuses a surviving instance's — and
   * past that the canonical was falling through to map order. `seq` is
   * that order, made explicit. Found by review of the go port. */
  size_t total = instcount(h);
  Inst **live = (Inst **)arena_alloc(sizeof(Inst *) * (total + 1));
  size_t n = 0;
  for (Inst *e = h->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->status, "live")) live[n++] = e;
  }
  for (size_t i = 0; i + 1 < n; i++) {
    for (size_t j = i + 1; j < n; j++) {
      if (live[j]->seq < live[i]->seq) { Inst *t = live[i]; live[i] = live[j]; live[j] = t; }
    }
  }

  Value *bindings = vlist();
  for (size_t i = 0; i < n; i++) {
    Value *b = vmap();
    vset(b, "ref", vstr(live[i]->ref));
    vset(b, "pos", vnum(live[i]->pos));
    if (!visnull(live[i]->order)) vset(b, "order", live[i]->order);
    vpush(bindings, b);
  }

  Value *spec = NULL == point ? NULL : vget(h->points, point);
  return resolveorder(bindings, vismap(spec) ? vget(spec, "pin") : NULL);
}

Value *host_positionof(Host *h, const char *ref, const char *point) {
  Value *ranked = host_order(h, point);
  const char *r = canonref(vstr(ref));
  double index = -1;
  for (size_t i = 0; i < vlen(ranked); i++) {
    if (0 == strcmp(vasstr(vat(ranked, i)), r)) { index = (double)i; break; }
  }
  Value *out = vmap();
  vset(out, "index", vnum(index));
  vset(out, "count", vnum((double)vlen(ranked)));
  /* §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST, so
   * these are not index 0 and count-1 the other way round. Getting this
   * backwards is the exact error the positional pin vocabulary exists
   * to prevent. */
  vset(out, "outermost", vbool(0 == index));
  vset(out, "innermost", vbool(index == (double)vlen(ranked) - 1));
  return out;
}

Value *inst_position(Inst *e, const char *point) {
  return host_positionof(e->owner, e->ref, point);
}

/* Live bindings on a point, in resolved order. Recomputed on any change
 * to the live set (§7) rather than cached at startup — the bug a host
 * discovers only when something deactivates in production. */
static size_t boundon(Host *h, const char *point, Bound ***out) {
  Value *ranked = host_order(h, point);
  size_t cap = 8, n = 0;
  Bound **list = (Bound **)arena_alloc(sizeof(Bound *) * cap);
  for (size_t i = 0; i < vlen(ranked); i++) {
    Inst *e = findinst(h, vasstr(vat(ranked, i)));
    if (NULL == e) continue;
    /* The band is the INSTANCE's ordering block (§7), stamped by the
     * host. A plugin passing its own would be ranking itself above the
     * order its document declared. */
    Value *band = vget(e->order, "band");
    double bandv = visnum(band) ? vasnum(band) : 0.0;
    for (size_t j = 0; j < e->nbindings; j++) {
      if (0 != strcmp(e->bindings[j]->point, point)) continue;
      if (n == cap) {
        cap *= 2;
        Bound **grown = (Bound **)arena_alloc(sizeof(Bound *) * cap);
        for (size_t k = 0; k < n; k++) grown[k] = list[k];
        list = grown;
      }
      Bound *b = (Bound *)arena_alloc(sizeof(Bound));
      *b = *e->bindings[j];
      b->band = bandv;
      list[n++] = b;
    }
  }
  *out = list;
  return n;
}

static Value *pointspec(Host *h, const char *point) {
  Value *spec = vget(h->points, point);
  if (!vhas(h->points, point)) {
    size_t sz = strlen(point) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "no such point: %s", point);
    fail("plugin_point_unknown", text, details1("point", vstr(point)));
  }
  return vismap(spec) ? spec : vmap();
}

static void checkkind(Value *spec, const char *point, const char *want) {
  Value *kind = vget(spec, "kind");
  const char *k = visstr(kind) ? vasstr(kind) : NULL;
  bool ok = (NULL == k) ? (0 == strcmp(want, "hook")) : (0 == strcmp(k, want));
  if (ok) return;
  size_t sz = strlen(point) + strlen(want) + 40;
  char *text = (char *)arena_alloc(sz);
  snprintf(text, sz, "point is not a %s: %s", want, point);
  Value *d = vmap();
  vset(d, "point", vstr(point));
  vset(d, "kind", NULL == k ? vnull() : vstr(k));
  fail("plugin_point_kind", text, d);
}

Value *host_emit(Host *h, const char *point, Value *arg) {
  Value *spec = pointspec(h, point);
  checkkind(spec, point, "hook");
  Bound **bindings;
  size_t n = boundon(h, point, &bindings);
  Value *mode = vget(spec, "mode");
  Value *errors = NULL;
  Value *out = point_emit(bindings, n, visstr(mode) ? vasstr(mode) : "emit",
                          arg, &errors);
  const char *m = visstr(mode) ? vasstr(mode) : "emit";
  if (0 == strcmp(m, "emit")) return NULL;
  if (0 == strcmp(m, "bail")) return out;
  return errors;
}

static HookFn basefor(Host *h, const char *point) {
  if (NULL == h->basefns || !vislist(h->basepoints)) return NULL;
  for (size_t i = 0; i < vlen(h->basepoints); i++) {
    if (0 == strcmp(vasstr(vat(h->basepoints, i)), point)) return h->basefns[i];
  }
  return NULL;
}

Value *host_call(Host *h, const char *point, Value *arg) {
  Value *spec = pointspec(h, point);
  checkkind(spec, point, "chain");
  Bound **bindings;
  size_t n = boundon(h, point, &bindings);
  /* The host owns the base and a plugin cannot replace it (§6.2). One
   * that wants to SUBSTITUTE rather than wrap binds innermost and
   * simply does not call `next`. */
  return point_call(bindings, n, basefor(h, point), NULL, arg);
}

Value *host_provider(Host *h, const char *point, Value *arg) {
  Value *spec = pointspec(h, point);
  checkkind(spec, point, "provider");
  Bound **bindings;
  size_t n = boundon(h, point, &bindings);
  Value *shadow = NULL;
  Bound *winner = point_provider(bindings, n,
                                 vtruthy(vget(spec, "exclusive")), &shadow);
  if (NULL == winner) return vget(spec, "default");
  return winner->hook(arg, winner->ctx);
}

Value *host_shadowed(Host *h, const char *point) {
  if (!vhas(h->points, point)) return vlist();
  Value *spec = vget(h->points, point);
  Bound **bindings;
  size_t n = boundon(h, point, &bindings);
  Value *shadow = NULL;
  point_provider(bindings, n,
                 vismap(spec) && vtruthy(vget(spec, "exclusive")), &shadow);
  return NULL == shadow ? vlist() : shadow;
}

Value *host_exports(Host *h, const char *spec) {
  Value *all = vlist();
  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    Inst *e = findinst(h, refs[i]);
    /* Exports of a `loaded` (not live) instance are VISIBLE (§11). */
    if (0 == strcmp(e->status, "declared") || 0 == strcmp(e->status, "failed")) continue;
    const char **keys;
    size_t kn = vkeys(e->exports, &keys);
    for (size_t j = 0; j < kn; j++) {
      Value *ex = vmap();
      vset(ex, "ref", vstr(refs[i]));
      vset(ex, "key", vstr(keys[j]));
      vset(ex, "value", vget(e->exports, keys[j]));
      vpush(all, ex);
    }
  }
  return resolveexport(vstr(spec), all);
}

Value *host_capability(Host *h, const char *name) {
  Value *cands = vlist();
  const char **refs;
  size_t n = sortedrefs(h, &refs);
  for (size_t i = 0; i < n; i++) {
    Inst *e = findinst(h, refs[i]);
    if (0 != strcmp(e->status, "live")) continue;
    for (size_t j = 0; j < vlen(e->provides); j++) {
      Value *p = vat(e->provides, j);
      if (visstr(vget(p, "name")) && 0 == strcmp(vasstr(vget(p, "name")), name)) {
        Value *c = vmap();
        vset(c, "ref", vstr(refs[i]));
        vset(c, "pos", vnum(e->pos));
        vset(c, "provides", p);
        vpush(cands, c);
      }
    }
  }
  Value *req = vmap();
  vset(req, "name", vstr(name));
  Value *ranked = resolvecapability(req, cands);
  Value *out = vlist();
  for (size_t i = 0; i < vlen(ranked); i++) vpush(out, vget(vat(ranked, i), "ref"));
  return out;
}

/* ------------------------------------------------------------------ */
/* the state machine                                                   */
/* ------------------------------------------------------------------ */

static void reconcile(Host *h);

const char *host_autotag(Host *h, const char *name) {
  /* AUTO-TAGGING IS EXPLICIT (§4 rule 3): the LOWEST UNUSED POSITIVE
   * INTEGER tag. It needs a host because it must know what is already
   * declared, which is why it cannot live in the pure `ref` section. */
  for (int n = 1;; n++) {
    char tag[32];
    snprintf(tag, sizeof(tag), "%d", n);
    const char *cand = formatref(vstr(name), vstr(tag));
    if (NULL == findinst(h, cand)) return cand;
  }
}

Inst *host_declare(Host *h, const char *ref, DeclareSpec *spec) {
  const char *r;
  if (NULL != spec && NULL != spec->tag && 0 == strcmp(spec->tag, "?")) {
    r = host_autotag(h, refname(canonref(vstr(ref))));
  }
  else {
    r = canonref(vstr(ref));
  }

  if (NULL == spec || !spec->hostowned) checkreserved(h, r);

  const char *defname = (NULL != spec && NULL != spec->definition)
    ? spec->definition : refname(r);
  Definition *def = catalog_get(h->catalog, defname);
  if (NULL == def) {
    size_t sz = strlen(defname) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "not in catalog: %s", defname);
    fail("plugin_unknown_definition", text, details1("name", vstr(defname)));
  }

  Inst *existing = findinst(h, r);
  if (NULL != existing) {
    /* §4 rule 1: a pair addresses at most one instance. Re-declaring the
     * SAME definition is the idempotent case; a different one is a
     * duplicate, not a silent overwrite (seneca) and not an
     * impossibility (sdkgen). */
    if (0 != strcmp(existing->def->name, def->name)) {
      size_t sz = strlen(r) + 40;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "instance already declared: %s", r);
      fail("plugin_ref_duplicate", text, details1("ref", vstr(r)));
    }
    return existing;
  }

  Inst *e = (Inst *)arena_alloc(sizeof(Inst));
  e->ref = arena_strdup(r);
  e->def = def;
  e->status = "declared";
  e->pos = (NULL != spec && spec->haspos) ? spec->pos : (double)instcount(h);
  e->seq = h->seqn++;
  /* NO OPTIONS ADOPTED HERE. `apply` resolves options and hands the map
   * over; adopting the caller's map made target and source THE SAME MAP
   * in the refill that follows, which cleared its own source and left a
   * first-time instance with no options at all. */
  e->options = (NULL != spec && vismap(spec->options)) ? spec->options : vmap();
  e->state = vmap();
  e->order = (NULL != spec) ? spec->order : NULL;
  e->selected = vmap();
  e->barred = false;
  e->unmet = vlist();
  e->scope = NULL;
  e->nscope = 0;
  e->capscope = 0;
  e->bindings = NULL;
  e->nbindings = 0;
  e->capbindings = 0;
  e->inner = NULL;
  e->exports = vmap();
  e->provides = vlist();
  e->owner = h;
  e->next = NULL;

  Inst **tail = &h->first;
  while (NULL != *tail) tail = &(*tail)->next;
  *tail = e;
  return e;
}

Inst *host_load(Host *h, const char *ref, DeclareSpec *spec) {
  guard(h);
  Inst *e = host_declare(h, ref, spec);
  if (0 != strcmp(e->status, "declared")) return e;   /* idempotent */
  /* PRESENT AND NOT NULL, not merely present. Every driver builds its
   * command spec with all four keys and a null for each absent one, so
   * a presence test reads an omitted `options` as an authored empty and
   * wipes the real ones. */
  if (NULL != spec && vismap(spec->options)) e->options = spec->options;

  CatchFrame f;
  if (0 == PLUGIN_TRY(&f)) {
    run(h, e, "define");
    PLUGIN_END(&f);
  }
  else {
    e->status = "failed";
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }
  e->status = "loaded";

  /* AT LOAD, and before anything runs: a cycle through restart-causing
   * requirements does not settle, and the only safe time to report a
   * non-terminating reconcile is before it starts (§11.3). `provides`
   * is populated by `define`, which has just run, so this is the first
   * moment the graph is complete. */
  if (0 == PLUGIN_TRY(&f)) {
    checkcycle(graphnodes(h));
    PLUGIN_END(&f);
  }
  else {
    e->status = "failed";
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }
  return e;
}

/* CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
 *
 * The cascade is part of the provider's own deactivation and runs
 * BEFORE the provider's `deactivate` callback and scope unwind, so a
 * consumer's teardown can still call the thing it depends on — flushing
 * a buffer to the store it is about to lose is exactly what a
 * `deactivate` callback is for. */
static void cascade(Host *h, Inst *provider, Value *seen) {
  if (vhas(seen, provider->ref)) return;
  vset(seen, provider->ref, vbool(true));

  Value *cons = consumersof(h, provider->ref);
  for (size_t i = 0; i < vlen(cons); i++) {
    Inst *c = findinst(h, vasstr(vat(cons, i)));
    if (NULL == c || 0 != strcmp(c->status, "live")) continue;
    cascade(h, c, seen);                    /* deepest-first */
    /* VOLATILE, and this is a correctness requirement rather than a
     * warning to silence: C guarantees only that `volatile` locals keep
     * their value across a `longjmp`, so a flag set before the jump and
     * read after it is indeterminate without this. Every local that
     * straddles a PLUGIN_TRY in this file is marked, and gcc's
     * -Wclobbered is what finds the ones a reader would miss. */
    volatile bool bad = false;
    CatchFrame f;
    if (0 == PLUGIN_TRY(&f)) {
      run(h, c, "deactivate");
      PLUGIN_END(&f);
    }
    else {
      bad = true;
    }
    Value *errors = unwind(h, c);
    if (bad || 0 < vlen(errors)) {
      /* §5.2: ANY failure during a transition lands the instance in
       * `failed`, and a cascaded consumer is not an exception. Marking
       * it `pending` instead handed it straight back to `reconcile`,
       * which would activate it again the moment the provider returned
       * — the one thing `failed` exists to stop. */
      c->status = "failed";
      continue;
    }
    c->status = "pending";
    c->unmet = unmetof(h, c);
  }
}

Inst *host_activate(Host *h, const char *ref) {
  guard(h);
  Inst *e = need(h, ref);
  if (0 == strcmp(e->status, "live")) return e;    /* no-op returning success */
  if (0 == strcmp(e->status, "failed")) {
    size_t sz = strlen(e->ref) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "instance has failed: %s", e->ref);
    fail("plugin_bad_state", text, details1("ref", vstr(e->ref)));
  }
  /* §9.6: `active: false` bars the instance from running, and the bar
   * is on the INSTANCE rather than on the apply that set it. `ready`
   * reaches this through `activate`, which is why one guard covers both
   * verbs the design names. */
  if (e->barred) {
    size_t sz = strlen(e->ref) + 48;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "instance is barred by active: false: %s", e->ref);
    fail("plugin_inactive", text, details1("ref", vstr(e->ref)));
  }
  if (0 == strcmp(e->status, "declared")) host_load(h, e->ref, NULL);

  /* A declared requirement that is not live means `pending`: activation
   * is a STANDING REQUEST, not a one-shot event. */
  Value *unmet = unmetof(h, e);
  if (0 < vlen(unmet)) {
    e->unmet = unmet;
    e->status = "pending";
    return e;
  }

  CatchFrame f;
  if (0 == PLUGIN_TRY(&f)) {
    run(h, e, "activate");
    PLUGIN_END(&f);
  }
  else {
    /* Unwind whatever the partial activation captured, in reverse. */
    unwind(h, e);
    e->status = "failed";
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }

  /* §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
   * later question — the cascade, `hold`, `unmet` — reads it back
   * rather than re-ranking, which is what "always-reluctant" means. */
  Value *reqs = requirements(e->options);
  for (size_t i = 0; i < vlen(reqs); i++) chosen(h, e, vat(reqs, i), true);
  e->status = "live";
  reconcile(h);
  return e;
}

Inst *host_deactivate(Host *h, const char *ref) {
  guard(h);
  Inst *e = need(h, ref);
  if (0 == strcmp(e->status, "loaded") || 0 == strcmp(e->status, "declared")) return e;

  /* §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`. Falling
   * through here ran the definition's `deactivate` on an instance that
   * never completed activation and, if that callback happened to
   * succeed, returned it to `loaded` — from where it could be activated
   * again, which is precisely what `failed` exists to prevent. */
  if (0 == strcmp(e->status, "failed")) {
    size_t sz = strlen(e->ref) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "instance has failed: %s", e->ref);
    fail("plugin_bad_state", text, details1("ref", vstr(e->ref)));
  }

  if (0 == strcmp(e->status, "pending")) {
    /* DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It never
     * reached activate, so it holds no scope and no live bindings;
     * running the definition's deactivate there would be teardown
     * without matching setup. It cannot fail. */
    e->status = "loaded";
    e->unmet = vlist();
    return e;
  }

  held(h, e);
  cascade(h, e, vmap());

  CatchFrame f;
  if (0 == PLUGIN_TRY(&f)) {
    run(h, e, "deactivate");
    PLUGIN_END(&f);
  }
  else {
    unwind(h, e);
    e->status = "failed";
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }
  releasecheck(e, unwind(h, e));
  e->status = "loaded";
  reconcile(h);
  return e;
}

void host_unload(Host *h, const char *ref) {
  guard(h);
  Inst *e = need(h, ref);
  if (0 == strcmp(e->status, "live") || 0 == strcmp(e->status, "pending")) {
    if (0 == strcmp(e->status, "live")) {
      held(h, e);
      cascade(h, e, vmap());
      CatchFrame f;
      if (0 == PLUGIN_TRY(&f)) {
        run(h, e, "deactivate");
        PLUGIN_END(&f);
      }
      else {
        /* §5.2: ANY failure during a transition lands the instance in
         * `failed`, with the scope STILL FULLY UNWOUND. An earlier
         * draft let the raise propagate straight out of `unload`, which
         * left the instance `live` and its scope untouched — reporting
         * a failure while leaking exactly the resources the failure was
         * about. */
        unwind(h, e);
        e->status = "failed";
        fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
      }
      releasecheck(e, unwind(h, e));
    }
    e->status = "loaded";
  }
  if (0 == strcmp(e->status, "loaded") || 0 == strcmp(e->status, "failed")) {
    CatchFrame f;
    if (0 == PLUGIN_TRY(&f)) {
      run(h, e, "close");
      PLUGIN_END(&f);
      removeinst(h, e);
      return;
    }
    removeinst(h, e);
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }
  removeinst(h, e);
}

Inst *host_ready(Host *h, const char *ref) {
  /* Runs the whole forward path in one call (§5.1). §15.2's verb list
   * omits this; §5.1 defines it and §15.3's `declare` row requires the
   * corpus to pin it, so the list was incomplete rather than excluding
   * it (DOCS.md §4.2). */
  guard(h);
  const char *r = canonref(vstr(ref));
  if (NULL == findinst(h, r)) host_declare(h, r, NULL);
  if (0 == strcmp(findinst(h, r)->status, "declared")) host_load(h, r, NULL);
  return host_activate(h, r);
}

/* EAGER reconciliation: run to a fixed point rather than scheduling.
 *
 * Two directions, and both are the reason `pending` exists. Activation
 * is a STANDING REQUEST, not a one-shot event: a pending instance whose
 * requirement arrives activates without being asked again, and a LIVE
 * instance whose requirement is lost goes back to pending —
 * recursively, through its own consumers. */
static void reconcile(Host *h) {
  bool moved = true;
  int rounds = 0;
  while (moved) {
    moved = false;
    if (1000 < ++rounds) break;

    /* Losses first, so a cascade settles in one pass rather than
     * alternating with re-activations. */
    const char **refs;
    volatile size_t n = sortedrefs(h, &refs);
    for (volatile size_t i = 0; i < n; i++) {
      Inst *e = findinst(h, refs[i]);
      if (NULL == e || 0 != strcmp(e->status, "live")) continue;
      Value *reqs = requirements(e->options);
      Value *lost = vlist();
      for (size_t j = 0; j < vlen(reqs); j++) {
        Value *q = vat(reqs, j);
        if (!gatesactivation(q)) continue;
        if (0 == vlen(providersof(h, q))) vpush(lost, q);
      }
      if (0 == vlen(lost)) continue;
      /* POLICY IS PER REQUIREMENT, not per instance (§11.3): only the
       * definition that has the requirement knows what it can cope
       * with, and one instance may hold both a `static` and a `dynamic`
       * one. A `dynamic` requirement whose provider is gone leaves the
       * consumer LIVE and notified. */
      bool anyrestart = false;
      for (size_t j = 0; j < vlen(lost); j++) {
        if (restartsonloss(vat(lost, j))) { anyrestart = true; break; }
      }
      if (!anyrestart) continue;

      volatile bool bad = false;
      CatchFrame f;
      if (0 == PLUGIN_TRY(&f)) {
        run(h, e, "deactivate");
        PLUGIN_END(&f);
      }
      else {
        bad = true;
      }
      Value *errors = unwind(h, e);
      if (bad || 0 < vlen(errors)) {
        e->status = "failed";
        moved = true;
        continue;
      }
      e->status = "pending";
      e->unmet = unmetof(h, e);
      moved = true;
    }

    n = sortedrefs(h, &refs);
    for (volatile size_t i = 0; i < n; i++) {
      Inst *e = findinst(h, refs[i]);
      if (NULL == e || 0 != strcmp(e->status, "pending")) continue;
      if (0 < vlen(unmetof(h, e))) continue;
      CatchFrame f;
      if (0 == PLUGIN_TRY(&f)) {
        run(h, e, "activate");
        PLUGIN_END(&f);
        Value *reqs = requirements(e->options);
        for (size_t j = 0; j < vlen(reqs); j++) chosen(h, e, vat(reqs, j), true);
        e->status = "live";
        e->unmet = vlist();
        moved = true;
      }
      else {
        unwind(h, e);
        e->status = "failed";
        moved = true;
      }
    }
  }
}

/* ------------------------------------------------------------------ */
/* documents                                                           */
/* ------------------------------------------------------------------ */

/* Empty the target and refill it, so callers holding the reference see
 * the new values. A definition's callbacks close over the options map
 * they were handed at `define`; replacing the reference would leave
 * every binding reading the values the first apply gave it. */
static void refill(Value *target, Value *source) {
  const char **keys;
  size_t n = vkeys(target, &keys);
  for (size_t i = 0; i < n; i++) vdel(target, keys[i]);
  n = vkeys(source, &keys);
  for (size_t i = 0; i < n; i++) vset(target, keys[i], vget(source, keys[i]));
}

static Value *shapeof(Host *h, const char *ref) {
  Definition *d = catalog_get(h->catalog, refname(ref));
  return NULL == d ? NULL : d->shape;
}

void host_apply(Host *h, Value *doc, Value *profile) {
  guard(h);
  Value *in = vmap();
  vset(in, "doc", doc);
  vset(in, "profile", visnull(profile) ? h->profile : profile);
  vset(in, "keys", h->keys);
  vset(in, "reserved", h->reserved);
  Value *norm = normalizeconfig(in);

  Value *want = vget(norm, "order");
  Value *optionsof = vmap();
  for (size_t i = 0; i < vlen(want); i++) {
    const char *ref = vasstr(vat(want, i));
    Value *oin = vmap();
    vset(oin, "ref", vstr(ref));
    vset(oin, "doc", doc);
    vset(oin, "profile", visnull(profile) ? h->profile : profile);
    vset(oin, "shape", shapeof(h, ref));
    if (vismap(h->defaults)) {
      vset(oin, "hostdefaults", vget(h->defaults, refname(ref)));
    }
    vset(optionsof, ref, resolveoptions(oin));
  }

  /* --- phase 1: deactivations and unloads, in REVERSE load order --- */
  Value *instances = vget(norm, "instance");
  size_t total = instcount(h);
  const char **drop = (const char **)arena_alloc(sizeof(char *) * (total + 1));
  size_t ndrop = 0;
  for (Inst *e = h->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->status, "declared")) continue;
    Value *ent = vget(instances, e->ref);
    bool wantlive = vismap(ent) && vtruthy(vget(ent, "active")) &&
      visstr(vget(ent, "start")) && 0 == strcmp(vasstr(vget(ent, "start")), "eager");
    if (!wantlive) drop[ndrop++] = e->ref;
  }
  /* Reverse load order: highest `pos` first, ref-descending for a tie,
   * so a consumer declared after its provider goes down first. */
  for (size_t i = 0; i + 1 < ndrop; i++) {
    for (size_t j = i + 1; j < ndrop; j++) {
      Inst *a = findinst(h, drop[i]);
      Inst *b = findinst(h, drop[j]);
      bool swap = (b->pos > a->pos) ||
        (b->pos == a->pos && 0 > strcmp(drop[j], drop[i]));
      if (swap) { const char *t = drop[i]; drop[i] = drop[j]; drop[j] = t; }
    }
  }
  for (size_t i = 0; i < ndrop; i++) host_unload(h, drop[i]);

  /* --- phase 2: declare and patch EVERYTHING, in load order -------- */
  for (size_t i = 0; i < vlen(want); i++) {
    const char *ref = vasstr(vat(want, i));
    Value *ent = vget(instances, ref);
    DeclareSpec spec;
    memset(&spec, 0, sizeof(spec));
    spec.order = vget(ent, "order");
    spec.haspos = true;
    spec.pos = vasnum(vget(ent, "pos"));
    host_declare(h, ref, &spec);
    Inst *e = findinst(h, ref);
    /* The bar is REASSERTED ON EVERY APPLY, in both directions — a
     * document that turns the instance back on clears it, which is the
     * whole point of a config switch. */
    e->barred = !vtruthy(vget(ent, "active"));
    refill(e->options, vget(optionsof, ref));
    e->order = vget(ent, "order");
    e->pos = vasnum(vget(ent, "pos"));
  }

  /* --- phase 3: loads, in load order ------------------------------- */
  for (size_t i = 0; i < vlen(want); i++) {
    const char *ref = vasstr(vat(want, i));
    Value *ent = vget(instances, ref);
    bool wantlive = vtruthy(vget(ent, "active")) &&
      visstr(vget(ent, "start")) && 0 == strcmp(vasstr(vget(ent, "start")), "eager");
    if (wantlive) host_load(h, ref, NULL);
  }

  /* --- phase 4: activations, in load order ------------------------- */
  for (size_t i = 0; i < vlen(want); i++) {
    const char *ref = vasstr(vat(want, i));
    Value *ent = vget(instances, ref);
    bool wantlive = vtruthy(vget(ent, "active")) &&
      visstr(vget(ent, "start")) && 0 == strcmp(vasstr(vget(ent, "start")), "eager");
    if (wantlive) host_activate(h, ref);
  }
}

void host_setoptions(Host *h, const char *ref, Value *patch) {
  guard(h);
  Inst *e = need(h, ref);
  Value *previous = vclone(e->options);
  Value *in = vmap();
  vset(in, "ref", vstr(e->ref));
  vset(in, "shape", shapeof(h, e->ref));
  vset(in, "doc", vmap());
  vset(in, "patch", plugin_merge(previous, patch));
  refill(e->options, resolveoptions(in));

  if (0 != strcmp(e->status, "live")) return;
  if (NULL != e->def->reconfigure) {
    h->intransition = true;
    h->phase = "reconfigure";
    CatchFrame f;
    if (0 == PLUGIN_TRY(&f)) {
      e->def->reconfigure(e, e->options, previous);
      PLUGIN_END(&f);
      h->intransition = false;
      h->phase = NULL;
      return;
    }
    h->intransition = false;
    h->phase = NULL;
    fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
  }
  /* Always correct and sometimes expensive; `reconfigure` exists to
   * make the common case cheap (§9.4). */
  host_deactivate(h, e->ref);
  host_activate(h, e->ref);
}

void host_close(Host *h) {
  /* A bulk teardown removing the holders too, so `hold` is suspended
   * for exactly those holders (§11.3) — while the consumers-first
   * cascade still runs, which is the half that matters. */
  h->coordinated = true;
  size_t total = instcount(h);
  const char **refs = (const char **)arena_alloc(sizeof(char *) * (total + 1));
  size_t n = 0;
  for (Inst *e = h->first; NULL != e; e = e->next) refs[n++] = e->ref;
  /* Reverse load order. */
  for (size_t i = 0; i + 1 < n; i++) {
    for (size_t j = i + 1; j < n; j++) {
      Inst *a = findinst(h, refs[i]);
      Inst *b = findinst(h, refs[j]);
      if (NULL == a || NULL == b) continue;
      bool swap = (b->pos > a->pos) ||
        (b->pos == a->pos && 0 > strcmp(refs[j], refs[i]));
      if (swap) { const char *t = refs[i]; refs[i] = refs[j]; refs[j] = t; }
    }
  }
  /* A COORDINATED FLAG THAT SURVIVES A RAISE IS A DISABLED GUARD. The
   * canonical wraps the teardown in `try/finally`; here an unload that
   * raises would skip the reset and leave the host permanently
   * `coordinated`, so a caller that catches the error and carries on
   * under `dependency: "hold"` gets ad-hoc deactivation with the holder
   * check silently off. Catch, reset, re-raise is C's `finally`. */
  volatile size_t i = 0;
  CatchFrame f;
  if (0 == PLUGIN_TRY(&f)) {
    for (; i < n; i++) {
      if (NULL != findinst(h, refs[i])) host_unload(h, refs[i]);
    }
    PLUGIN_END(&f);
    h->coordinated = false;
    return;
  }
  h->coordinated = false;
  fail(plugin_caught()->code, plugin_caught()->text, plugin_caught()->details);
}
