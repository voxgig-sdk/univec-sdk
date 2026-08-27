// Cost tracking and spend budget (mirrors ts
// src/feature/cost/CostFeature.ts). Uses BOTH seams, which is the point of
// the feature: money is spent per HTTP ATTEMPT (a retried call is charged
// again, because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and PreDone
// attributes the running total to `<entity>.<op>` and to the caller (the
// per-call ctrl actor, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// `<entity>.<op>` / `<op>` / `*`), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at PreDone
// instead, from the already-parsed result, and describes the whole call, so
// it REPLACES the per-attempt estimate rather than adding to it.
//
// `budget` caps total spend. With `onBudget: "deny"` a further operation is
// refused at PrePoint (via ctx.out point, which make_point surfaces), before
// an endpoint is resolved and before anything reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent. The default (map) order
// puts cache innermost and cost outside it, so activate them in list form
// with cost first.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define COST_PENDING_KEY "cost_pending"

typedef struct {
  int64_t calls;
  double amount;
} CostBucket;

// A find-or-insert string->bucket map as parallel growable arrays, the same
// shape metrics uses for its per-op buckets.
typedef struct {
  char** keys;
  CostBucket* buckets;
  size_t len;
  size_t cap;
} CostMap;

typedef struct {
  // Aggregates (mirrors the ts client._cost record).
  char* currency;
  int64_t calls;
  int64_t attempts;
  double amount;
  double reported;
  double estimated;
  CostMap ops;
  CostMap actors;
  double limit;
  double spent;
  double remaining;
  bool exceeded;
  voxgig_value* last;
  int64_t seq;
} CostTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  CostTrack* track;
} CostFeature;

typedef struct {
  Fetcher* inner;
  voxgig_value* options;
  CostTrack* track;
} CostState;

static CostBucket* cost_map_entry(CostMap* m, const char* key) {
  for (size_t i = 0; i < m->len; i++) {
    if (strcmp(m->keys[i], key) == 0) return &m->buckets[i];
  }
  if (m->len == m->cap) {
    size_t nc = m->cap ? m->cap * 2 : 8;
    m->keys = (char**)realloc(m->keys, nc * sizeof(char*));
    m->buckets = (CostBucket*)realloc(m->buckets, nc * sizeof(CostBucket));
    m->cap = nc;
  }
  m->keys[m->len] = strdup(key);
  memset(&m->buckets[m->len], 0, sizeof(CostBucket));
  return &m->buckets[m->len++];
}

static void cost_bump(CostMap* m, const char* key, double amount) {
  CostBucket* b = cost_map_entry(m, key);
  b->calls += 1;
  b->amount += amount;
}

static char* cost_dot_join(const char* a, const char* b) {
  size_t na = a ? strlen(a) : 0;
  size_t nb = b ? strlen(b) : 0;
  char* s = (char*)malloc(na + nb + 2);
  memcpy(s, a ? a : "", na);
  s[na] = '.';
  memcpy(s + na + 1, b ? b : "", nb);
  s[na + 1 + nb] = '\0';
  return s;
}

// The model records the body figure as a dot path; getpath_c takes a
// NULL-terminated segment array. Sized from the path itself so a long path is
// never silently truncated. (paging.c carries its own copy for the same
// reason: feature source is trimmed per project, so a shared static helper
// would vanish with whichever feature happened to own it.)
// Defined below; `through` commits raw (unpipelined) calls through it.
static void cost_commit(CostTrack* t, voxgig_value* options, Context* ctx,
                        voxgig_value* pending, const char* entity, const char* opname);

// A fresh per-operation accumulator.
static voxgig_value* cost_new_pending(void) {
  return cmap(6, "attempts", v_num(0), "amount", v_num(0), "reported", v_num(0),
              "estimated", v_num(0), "source", v_str("none"), "piped", v_num(0));
}

static voxgig_value* cost_getpath_dotted(voxgig_value* store, const char* path) {
  if (!path || path[0] == '\0') return store;

  size_t len = strlen(path);
  size_t maxseg = 2;
  for (size_t i = 0; i < len; i++) {
    if (path[i] == '.') maxseg++;
  }

  char* buf = (char*)malloc(len + 1);
  const char** keys = (const char**)malloc(maxseg * sizeof(char*));
  if (!buf || !keys) {
    free(buf);
    free(keys);
    return voxgig_new_undef();
  }
  memcpy(buf, path, len + 1);

  size_t n = 0;
  char* seg = buf;
  for (char* p = buf;; p++) {
    if (*p == '.' || *p == '\0') {
      bool end = (*p == '\0');
      *p = '\0';
      if (seg[0] != '\0') keys[n++] = seg;
      seg = p + 1;
      if (end) break;
    }
  }
  keys[n] = NULL;

  voxgig_value* out = getpath_c(store, keys);
  free(buf);
  free(keys);
  return out;
}

static double cost_per_unit(voxgig_value* options) {
  return fopt_num(options, "perUnit", 0.0);
}

// The rate table uses the same lookup grammar as rbac's rules:
// `<entity>.<op>`, then `<op>`, then `*`.
static bool cost_rate(voxgig_value* options, Context* ctx, double* out) {
  voxgig_value* rates = fopt_map(options, "rates");
  if (!v_is_map(rates)) return false;

  const char* entity = ctx->op ? ctx->op->entity : "";
  const char* opname = ctx->op ? ctx->op->name : "";
  char* joined = cost_dot_join(entity, opname);

  const char* keys[3];
  keys[0] = joined;
  keys[1] = opname;
  keys[2] = "*";

  bool found = false;
  for (int i = 0; i < 3 && !found; i++) {
    voxgig_value* v = getp(rates, keys[i]);
    if (voxgig_is_number(v)) {
      *out = voxgig_as_double(v);
      found = true;
    }
  }

  free(joined);
  return found;
}

// Price one attempt: a reported header figure, else the rate table, else the
// flat unit. `source` receives a static string.
static double cost_price(voxgig_value* options, Context* ctx, voxgig_value* res,
                         const char** source) {
  const char* header = fopt_str(options, "header", "");
  if (header[0] != '\0') {
    const char* raw = fres_header(res, header);
    if (raw && raw[0] != '\0') {
      char* endp = NULL;
      double n = strtod(raw, &endp);
      if (endp != raw) {
        *source = "header";
        return n * cost_per_unit(options);
      }
    }
  }

  double rate = 0.0;
  if (cost_rate(options, ctx, &rate)) {
    *source = "table";
    return rate;
  }

  double unit = fopt_num(options, "unit", 0.0);
  if (unit != 0.0) {
    *source = "unit";
    return unit;
  }

  *source = "none";
  return 0.0;
}

// A usage figure from the parsed result body, priced by perUnit. Read here,
// not at the transport seam, because the body is one-shot.
static bool cost_body_amount(voxgig_value* options, Context* ctx, double* out) {
  const char* path = fopt_str(options, "path", "");
  if (path[0] == '\0') return false;
  if (!ctx->result || !ctx->result->body) return false;

  voxgig_value* v = cost_getpath_dotted(ctx->result->body, path);
  if (voxgig_is_number(v)) {
    *out = voxgig_as_double(v) * cost_per_unit(options);
    return true;
  }
  if (v_is_str(v)) {
    const char* s = voxgig_as_string(v);
    if (s) {
      char* endp = NULL;
      double n = strtod(s, &endp);
      if (endp != s) {
        *out = n * cost_per_unit(options);
        return true;
      }
    }
  }
  return false;
}

static void cost_spend(CostTrack* t, double amount, double reported, double estimated) {
  t->amount += amount;
  t->reported += reported;
  t->estimated += estimated;

  t->spent = t->amount;
  if (t->limit > 0.0) {
    t->remaining = t->limit - t->amount;
    if (t->remaining < 0.0) t->remaining = 0.0;
    if (t->amount >= t->limit) t->exceeded = true;
  } else {
    t->remaining = 0.0;
  }
}

static voxgig_value* through(Fetcher* self, Context* ctx, const char* url,
                             voxgig_value* fetchdef, PNError** err) {
  CostState* st = (CostState*)self->state;
  voxgig_value* options = st->options;
  CostTrack* track = st->track;

  voxgig_value* out = st->inner->fn(st->inner, ctx, url, fetchdef, err);

  const char* source = "none";
  double amount = cost_price(options, ctx, out, &source);

  // Accumulated on the context, committed once at PreDone. Adding each
  // attempt to the running total and then subtracting it again when a body
  // figure supersedes it loses precision to catastrophic cancellation.
  voxgig_value* pending = ctx_out_extra_get(ctx, COST_PENDING_KEY);
  if (!v_is_map(pending)) {
    pending = cost_new_pending();
  }

  double prev_amount = 0.0;
  int64_t prev_attempts = 0;
  bool piped = false;
  voxgig_value* pa = getp(pending, "amount");
  if (voxgig_is_number(pa)) prev_amount = voxgig_as_double(pa);
  voxgig_value* pn = getp(pending, "attempts");
  if (voxgig_is_number(pn)) prev_attempts = (int64_t)voxgig_as_double(pn);
  voxgig_value* pp = getp(pending, "piped");
  if (voxgig_is_number(pp)) piped = voxgig_as_double(pp) != 0.0;

  // Reported and estimated are kept apart per ATTEMPT: a 503 priced from the
  // rate table followed by a 200 carrying the cost header is part estimate,
  // part reported, and collapsing both into the final attempt's category
  // would corrupt the split.
  //
  // A failed transport arrives through the err out-param here, not as a
  // longjmp, so it already reaches this point and is priced from the table or
  // unit - no separate catch is needed, unlike the ts/js ports.
  const char* bucket =
      (strcmp(source, "header") == 0 || strcmp(source, "body") == 0) ? "reported" : "estimated";
  double prev_bucket = 0.0;
  voxgig_value* pb = getp(pending, bucket);
  if (voxgig_is_number(pb)) prev_bucket = voxgig_as_double(pb);

  setp(pending, "attempts", v_num((double)(prev_attempts + 1)));
  setp(pending, "amount", v_num(prev_amount + amount));
  setp(pending, bucket, v_num(prev_bucket + amount));
  setp(pending, "source", v_str(source));

  track->attempts += 1;

  // direct() and graphql() reach the transport without dispatching any
  // pipeline hooks, so there is no PrePoint to gate on and no PreDone to
  // commit. Their spend is committed here, or it would never be counted.
  if (!piped) {
    cost_commit(track, options, ctx, pending, "_", "direct");
    ctx_out_extra_set(ctx, COST_PENDING_KEY, v_undef());
  } else {
    ctx_out_extra_set(ctx, COST_PENDING_KEY, pending);
  }

  return out;
}

// The budget gate. Runs before endpoint resolution, so a refused call costs
// nothing at all.
static void cost_pre_point(CostFeature* cf, Context* ctx) {
  if (!cf->active) return;

  // Mark the context as running through the pipeline, so `through` knows a
  // PreDone is coming and does not commit the spend itself.
  voxgig_value* pending = ctx_out_extra_get(ctx, COST_PENDING_KEY);
  if (!v_is_map(pending)) {
    pending = cost_new_pending();
  }
  setp(pending, "piped", v_num(1));
  ctx_out_extra_set(ctx, COST_PENDING_KEY, pending);

  CostTrack* t = cf->track;
  if (t->limit <= 0.0 || t->amount < t->limit) return;

  t->exceeded = true;

  if (strcmp(fopt_str(cf->options, "onBudget", "warn"), "deny") != 0) return;

  char msg[320];
  snprintf(msg, sizeof(msg), "Cost budget of %g %s is spent (%g %s used)", t->limit,
           t->currency, t->amount, t->currency);
  PNError* err = context_make_error(ctx, "cost_budget", msg);

  // Short-circuit endpoint resolution; make_point surfaces this error before
  // any network activity.
  ctx_out_set_point_err(ctx, err);
}

// Commit one operation's spend: totals, budget, per-op and per-actor
// attribution, and the record. Shared by cost_finish and the raw-request path
// in through, which has no PreDone to reach.
static void cost_commit(CostTrack* t, voxgig_value* options, Context* ctx,
                        voxgig_value* pending, const char* entity, const char* opname) {
  double amount = 0.0;
  double reported = 0.0;
  double estimated = 0.0;
  int64_t attempts = 0;
  const char* source = "none";

  voxgig_value* pa = getp(pending, "amount");
  if (voxgig_is_number(pa)) amount = voxgig_as_double(pa);
  voxgig_value* pr = getp(pending, "reported");
  if (voxgig_is_number(pr)) reported = voxgig_as_double(pr);
  voxgig_value* pe = getp(pending, "estimated");
  if (voxgig_is_number(pe)) estimated = voxgig_as_double(pe);
  voxgig_value* pn = getp(pending, "attempts");
  if (voxgig_is_number(pn)) attempts = (int64_t)voxgig_as_double(pn);
  voxgig_value* ps = getp(pending, "source");
  if (v_is_str(ps)) {
    const char* sv = voxgig_as_string(ps);
    if (sv) source = sv;
  }

  // A body figure prices the whole call, so it replaces the per-attempt
  // estimate rather than adding to it, and being server-stated the whole
  // amount counts as reported.
  double body = 0.0;
  if (cost_body_amount(options, ctx, &body)) {
    amount = body;
    reported = body;
    estimated = 0.0;
    source = "body";
  }

  cost_spend(t, amount, reported, estimated);

  const char* actor = "anonymous";
  const char* opt_actor = fopt_str(options, "actor", "");
  if (opt_actor[0] != '\0') actor = opt_actor;
  if (ctx->ctrl && ctx->ctrl->actor && ctx->ctrl->actor[0] != '\0') actor = ctx->ctrl->actor;

  t->calls += 1;
  char* key = cost_dot_join(entity, opname);
  cost_bump(&t->ops, key, amount);
  free(key);
  cost_bump(&t->actors, actor, amount);

  t->seq += 1;
  voxgig_value* record =
      cmap(8, "seq", v_num((double)t->seq), "entity", v_str(entity), "op", v_str(opname),
           "actor", v_str(actor), "amount", v_num(amount), "currency", v_str(t->currency),
           "source", v_str(source), "attempts", v_num((double)attempts));
  t->last = record;

  voxgig_value* sink = getp(options, "sink");
  if (voxgig_is_func(sink)) {
    call_vfn(sink, record);
  }
}

// Attribute the operation's spend once the call is finished. PreDone and
// PreUnexpected share this: a FAILED operation still spent the money, and when
// the pipeline errors PreDone never runs. Whichever hook fires first consumes
// the pending entry, so it commits exactly once.
static void cost_finish(CostFeature* cf, Context* ctx, bool done) {
  if (!cf->active) return;

  voxgig_value* pending = ctx_out_extra_get(ctx, COST_PENDING_KEY);
  if (!v_is_map(pending)) return;
  ctx_out_extra_set(ctx, COST_PENDING_KEY, v_undef());

  // A FAILED operation that made no attempt never reached the network:
  // PrePoint creates the pending entry to mark the context as piped, and
  // then the budget gate refuses the call (rbac, or an unresolvable
  // endpoint, short-circuits just as early). Committing it would count a
  // call that never happened and file a zero-amount record as `last`.
  //
  // A SUCCEEDED operation that made no attempt is the opposite case: it was
  // served from the cache. That is a real call, and the fact that it cost
  // nothing is the whole point of ordering cost inside the cache.
  if (!done) {
    voxgig_value* an = getp(pending, "attempts");
    if (!voxgig_is_number(an) || 0 == (int64_t)voxgig_as_double(an)) return;
  }

  const char* entity = (ctx->op && ctx->op->entity[0] != '\0') ? ctx->op->entity : "_";
  const char* opname = (ctx->op && ctx->op->name[0] != '\0') ? ctx->op->name : "_";

  cost_commit(cf->track, cf->options, ctx, pending, entity, opname);
}

static const char* cost_name(Feature* f) { return ((CostFeature*)f)->name; }
static bool cost_active(Feature* f) { return ((CostFeature*)f)->active; }
static voxgig_value* cost_add_options(Feature* f) { return ((CostFeature*)f)->add_opts; }

static void cost_init(Feature* f, Context* ctx, voxgig_value* options) {
  CostFeature* cf = (CostFeature*)f;
  cf->options = options;
  cf->active = fopt_bool(options, "active", false);

  CostTrack* t = cf->track;
  double limit = fopt_num(options, "budget", 0.0);

  free(t->currency);
  t->currency = strdup(fopt_str(options, "currency", "USD"));
  t->calls = 0;
  t->attempts = 0;
  t->amount = 0.0;
  t->reported = 0.0;
  t->estimated = 0.0;
  t->ops.len = 0;
  t->actors.len = 0;
  t->limit = limit;
  t->spent = 0.0;
  t->remaining = limit;
  t->exceeded = false;
  t->last = voxgig_new_undef();
  t->seq = 0;

  if (!cf->active) return;

  Utility* util = context_util(ctx);
  CostState* st = (CostState*)calloc(1, sizeof(CostState));
  st->inner = util->fetcher;
  st->options = options;
  st->track = t;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = through;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void cost_hook(Feature* f, const char* name, Context* ctx) {
  CostFeature* cf = (CostFeature*)f;
  if (strcmp(name, "PrePoint") == 0) {
    cost_pre_point(cf, ctx);
  } else if (strcmp(name, "PreDone") == 0) {
    cost_finish(cf, ctx, true);
  } else if (strcmp(name, "PreUnexpected") == 0) {
    cost_finish(cf, ctx, false);
  }
}

static voxgig_value* cost_map_value(const CostMap* m) {
  voxgig_value* out = v_map();
  for (size_t i = 0; i < m->len; i++) {
    setp(out, m->keys[i],
         cmap(2, "calls", v_num((double)m->buckets[i].calls), "amount",
              v_num(m->buckets[i].amount)));
  }
  return out;
}

static voxgig_value* cost_track(Feature* f) {
  CostFeature* cf = (CostFeature*)f;
  CostTrack* t = cf->track;
  return cmap(
      6, "currency", v_str(t->currency), "total",
      cmap(5, "calls", v_num((double)t->calls), "attempts", v_num((double)t->attempts),
           "amount", v_num(t->amount), "reported", v_num(t->reported), "estimated",
           v_num(t->estimated)),
      "ops", cost_map_value(&t->ops), "actors", cost_map_value(&t->actors), "budget",
      cmap(4, "limit", v_num(t->limit), "spent", v_num(t->spent), "remaining",
           v_num(t->remaining), "exceeded", t->exceeded ? v_num(1) : v_num(0)),
      "last", t->last);
}

static const FeatureVT COST_VT = {
  cost_name, cost_active, cost_add_options, cost_init, cost_hook, cost_track,
};

Feature* feature_cost_new(void) {
  CostFeature* cf = (CostFeature*)calloc(1, sizeof(CostFeature));
  cf->base.vt = &COST_VT;
  cf->name = strdup("cost");
  cf->active = true;
  cf->add_opts = NULL;
  cf->options = voxgig_new_undef();
  cf->track = (CostTrack*)calloc(1, sizeof(CostTrack));
  cf->track->currency = strdup("USD");
  cf->track->last = voxgig_new_undef();
  return (Feature*)cf;
}
