// Network behaviour simulation (mirrors feature/netsim.rs). Wraps the active
// transport (the live fetch or the `test` feature's in-memory mock) and
// injects realistic network conditions so offline unit tests can exercise
// slowness, transient failures, rate limiting and outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests are
// reproducible without mocking timers. `failRate` adds optional pseudo-random
// failures via a seeded LCG for coverage-style testing.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int64_t seed;

  // Activity tracking (mirrors the ts client._netsim record).
  int64_t calls;
  voxgig_value* applied; // List of applied-condition maps
} NetsimTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  NetsimTrack* track;
} NetsimFeature;

typedef struct {
  NetsimTrack* track;
  voxgig_value* options;
  Fetcher* inner;
} NetsimState;

// A deterministic 0..1 pseudo-random via a linear congruential generator.
static double lcg_rand(NetsimTrack* t) {
  // seed = (seed*1103515245 + 12345) & 0x7fffffff  (wrapping, i64->u64 exact)
  uint64_t s = (uint64_t)t->seed;
  s = s * 1103515245ULL + 12345ULL;
  t->seed = (int64_t)(s & 0x7fffffffULL);
  return (double)t->seed / (double)0x7fffffff;
}

// pick_latency yields ms: a fixed number, or a uniform sample from {min,max}.
static int64_t pick_latency(NetsimTrack* track, voxgig_value* options) {
  voxgig_value* l = getp(options, "latency");
  if (v_is_noval(l) || v_is_null(l)) {
    return 0;
  }
  if (voxgig_is_map(l)) {
    int64_t min = fopt_int(l, "min", 0);
    int64_t max = fopt_int(l, "max", min);
    if (max <= min) {
      return min;
    }
    return min + (int64_t)(lcg_rand(track) * (double)(max - min));
  }
  int64_t v = fopt_int(options, "latency", 0);
  return v > 0 ? v : 0;
}

static void track_applied(NetsimState* st, Context* ctx, voxgig_value* applied) {
  NetsimTrack* t = st->track;
  voxgig_list_push(voxgig_as_list(t->applied), applied);
  int64_t calls = t->calls;

  // Snapshot the applied list (mirrors Value::list(t.applied.clone())).
  voxgig_value* applied_list = v_list();
  voxgig_list* al = voxgig_as_list(t->applied);
  for (size_t i = 0; i < al->len; i++) {
    voxgig_list_push(voxgig_as_list(applied_list), voxgig_retain(al->items[i]));
  }

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "netsim",
         cmap(2, "calls", v_num((double)calls), "applied", applied_list));
  }
}

// respond builds a transport-shaped response (matching the test feature's
// mock) that the result pipeline understands.
static voxgig_value* respond(int64_t status, voxgig_value* data) {
  return cmap(5, "status", v_num((double)status), "statusText", v_str("OK"), "json",
              json_thunk(data), "body", v_str("not-used"), "headers", v_map());
}

static voxgig_value* netsim_fetch(Fetcher* self, Context* ctx, const char* url,
                                  voxgig_value* fetchdef, PNError** err) {
  NetsimState* st = (NetsimState*)self->state;
  NetsimTrack* track = st->track;
  voxgig_value* opts = st->options;
  *err = NULL;

  int64_t call = ++track->calls;

  // Total outage: every call fails at the transport level.
  if (fopt_bool(opts, "offline", false)) {
    fopt_sleep_call(opts, pick_latency(track, opts));
    track_applied(st, ctx, cmap(1, "offline", v_bool(true)));
    char msg[640];
    snprintf(msg, sizeof(msg), "Simulated network offline (URL was: \"%s\")", url);
    *err = context_make_error(ctx, "netsim_offline", msg);
    return NULL;
  }

  // Connection-level errors for the first N calls (e.g. ECONNRESET).
  if (call <= fopt_int(opts, "errorTimes", 0)) {
    fopt_sleep_call(opts, pick_latency(track, opts));
    track_applied(st, ctx, cmap(1, "error", v_bool(true)));
    char msg[128];
    snprintf(msg, sizeof(msg), "Simulated connection error (call %lld)", (long long)call);
    *err = context_make_error(ctx, "netsim_conn", msg);
    return NULL;
  }

  // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
  if (call <= fopt_int(opts, "rateLimitTimes", 0)) {
    fopt_sleep_call(opts, pick_latency(track, opts));
    track_applied(st, ctx, cmap(1, "rateLimited", v_bool(true)));
    char rabuf[32];
    snprintf(rabuf, sizeof(rabuf), "%lld", (long long)fopt_int(opts, "retryAfter", 0));
    voxgig_value* headers = cmap(1, "retry-after", v_str(rabuf));
    voxgig_value* r = respond(429, v_undef());
    setp(r, "statusText", v_str("Too Many Requests"));
    setp(r, "headers", headers);
    return r;
  }

  // Retryable failure status for the first N calls, or every Nth call, or
  // pseudo-randomly at `failRate`.
  int64_t fail_status = fopt_int(opts, "failStatus", 503);
  int64_t fail_every = fopt_int(opts, "failEvery", 0);
  bool fail_by_count = call <= fopt_int(opts, "failTimes", 0);
  bool fail_by_every = fail_every > 0 && call % fail_every == 0;
  double fail_rate = fopt_num(opts, "failRate", 0.0);
  bool fail_by_rate = fail_rate > 0.0 && lcg_rand(track) < fail_rate;
  if (fail_by_count || fail_by_every || fail_by_rate) {
    fopt_sleep_call(opts, pick_latency(track, opts));
    track_applied(st, ctx, cmap(1, "failStatus", v_num((double)fail_status)));
    voxgig_value* r = respond(fail_status, v_undef());
    setp(r, "statusText", v_str("Simulated Failure"));
    return r;
  }

  // Otherwise: apply latency then delegate to the real transport.
  int64_t latency = pick_latency(track, opts);
  track_applied(st, ctx, cmap(1, "latency", v_num((double)latency)));
  fopt_sleep_call(opts, latency);
  return st->inner->fn(st->inner, ctx, url, fetchdef, err);
}

static const char* netsim_name(Feature* f) { return ((NetsimFeature*)f)->name; }
static bool netsim_active(Feature* f) { return ((NetsimFeature*)f)->active; }
static voxgig_value* netsim_add_options(Feature* f) { return ((NetsimFeature*)f)->add_opts; }

static void netsim_init(Feature* f, Context* ctx, voxgig_value* options) {
  NetsimFeature* nf = (NetsimFeature*)f;
  nf->options = options;
  nf->active = fopt_bool(options, "active", false);

  nf->track->seed = fopt_int(options, "seed", 0);
  if (nf->track->seed == 0) {
    nf->track->seed = 1;
  }

  if (!nf->active) return;

  Utility* util = context_util(ctx);
  NetsimState* st = (NetsimState*)calloc(1, sizeof(NetsimState));
  st->track = nf->track;
  st->options = options;
  st->inner = util->fetcher;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = netsim_fetch;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void netsim_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* netsim_track(Feature* f) {
  NetsimTrack* t = ((NetsimFeature*)f)->track;
  return cmap(1, "calls", v_num((double)t->calls));
}

static const FeatureVT NETSIM_VT = {
  netsim_name, netsim_active, netsim_add_options, netsim_init, netsim_hook,
  netsim_track,
};

Feature* feature_netsim_new(void) {
  NetsimFeature* nf = (NetsimFeature*)calloc(1, sizeof(NetsimFeature));
  nf->base.vt = &NETSIM_VT;
  nf->name = strdup("netsim");
  nf->active = true; // matches rust new() (overridden by init from options)
  nf->add_opts = NULL;
  nf->options = voxgig_new_undef();
  nf->track = (NetsimTrack*)calloc(1, sizeof(NetsimTrack));
  nf->track->seed = 0;
  nf->track->calls = 0;
  nf->track->applied = voxgig_new_list();
  return (Feature*)nf;
}
