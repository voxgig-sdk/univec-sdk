// Client-side rate limiting via a token bucket (mirrors feature/
// ratelimit.rs). Each request consumes a token; when the bucket is empty the
// request waits until the bucket refills at `rate` tokens per second (with
// capacity `burst`, default: rate). The clock (`now`) and the wait (`sleep`)
// are injectable so the accounting can be tested deterministically.

#include "sdk.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  double tokens;
  int64_t last;

  // Activity tracking (mirrors the ts client._ratelimit record).
  int64_t throttled;
  int64_t wait_ms;
} RatelimitTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  RatelimitTrack* track;
} RatelimitFeature;

typedef struct {
  Fetcher* inner;
  voxgig_value* options;
  RatelimitTrack* track;
} RatelimitState;

static void acquire(RatelimitTrack* t, voxgig_value* options) {
  double rate = fopt_num(options, "rate", 5.0);
  double burst = fopt_num(options, "burst", rate);

  // Refill according to elapsed time.
  int64_t now = fopt_now_call(options);
  int64_t elapsed = now - t->last;
  t->last = now;
  double refilled = t->tokens + ((double)elapsed / 1000.0) * rate;
  t->tokens = burst < refilled ? burst : refilled; // burst.min(...)

  if (t->tokens >= 1.0) {
    t->tokens -= 1.0;
    return;
  }

  // Not enough tokens: wait for one to accrue, then consume it.
  double needed = 1.0 - t->tokens;
  int64_t wait_ms = (int64_t)ceil((needed / rate) * 1000.0);
  t->throttled += 1;
  t->wait_ms += wait_ms;

  if (wait_ms > 0) {
    fopt_sleep_call(options, wait_ms);
  }
  t->last = fopt_now_call(options);
  t->tokens = 0.0;
}

static voxgig_value* ratelimit_fetch(Fetcher* self, Context* ctx, const char* url,
                                     voxgig_value* fetchdef, PNError** err) {
  RatelimitState* st = (RatelimitState*)self->state;
  acquire(st->track, st->options);
  return st->inner->fn(st->inner, ctx, url, fetchdef, err);
}

static const char* ratelimit_name(Feature* f) { return ((RatelimitFeature*)f)->name; }
static bool ratelimit_active(Feature* f) { return ((RatelimitFeature*)f)->active; }
static voxgig_value* ratelimit_add_options(Feature* f) { return ((RatelimitFeature*)f)->add_opts; }

static void ratelimit_init(Feature* f, Context* ctx, voxgig_value* options) {
  RatelimitFeature* rf = (RatelimitFeature*)f;
  rf->options = options;
  rf->active = fopt_bool(options, "active", false);
  if (!rf->active) return;

  double rate = fopt_num(options, "rate", 5.0);
  double burst = fopt_num(options, "burst", rate);
  rf->track->tokens = burst;
  rf->track->last = fopt_now_call(options);

  Utility* util = context_util(ctx);
  RatelimitState* st = (RatelimitState*)calloc(1, sizeof(RatelimitState));
  st->inner = util->fetcher;
  st->options = options;
  st->track = rf->track;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = ratelimit_fetch;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void ratelimit_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* ratelimit_track(Feature* f) {
  RatelimitTrack* t = ((RatelimitFeature*)f)->track;
  return cmap(2, "throttled", v_num((double)t->throttled),
              "waitMs", v_num((double)t->wait_ms));
}

static const FeatureVT RATELIMIT_VT = {
  ratelimit_name, ratelimit_active, ratelimit_add_options, ratelimit_init, ratelimit_hook,
  ratelimit_track,
};

Feature* feature_ratelimit_new(void) {
  RatelimitFeature* rf = (RatelimitFeature*)calloc(1, sizeof(RatelimitFeature));
  rf->base.vt = &RATELIMIT_VT;
  rf->name = strdup("ratelimit");
  rf->active = true; // matches rust default (overridden by init from options)
  rf->add_opts = NULL;
  rf->options = voxgig_new_undef();
  rf->track = (RatelimitTrack*)calloc(1, sizeof(RatelimitTrack));
  return (Feature*)rf;
}
