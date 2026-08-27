// Per-request timeout (mirrors feature/timeout.rs). The active transport is
// wrapped with a deadline of `ms` milliseconds (default 30000; <= 0
// disables). The transport is synchronous, so the elapsed (injectable `now`)
// clock is checked around the inner call: when the call took longer than the
// deadline its result is discarded and a `timeout` error is returned instead.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  // Activity tracking (mirrors the ts client._timeout record).
  int64_t count;
  int64_t ms;
} TimeoutTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  TimeoutTrack* track;
} TimeoutFeature;

typedef struct {
  Fetcher* inner;
  voxgig_value* options;
  TimeoutTrack* track;
} TimeoutState;

static voxgig_value* timeout_fetch(Fetcher* self, Context* ctx, const char* url,
                                   voxgig_value* fetchdef, PNError** err) {
  TimeoutState* st = (TimeoutState*)self->state;
  voxgig_value* options = st->options;

  int64_t ms = fopt_int(options, "ms", 30000);
  if (ms <= 0) {
    return st->inner->fn(st->inner, ctx, url, fetchdef, err);
  }

  int64_t start = fopt_now_call(options);
  PNError* e = NULL;
  voxgig_value* out = st->inner->fn(st->inner, ctx, url, fetchdef, &e);

  if (fopt_now_call(options) - start > ms) {
    st->track->count += 1;
    st->track->ms = ms;
    char msg[64];
    snprintf(msg, sizeof(msg), "Request exceeded timeout of %lldms", (long long)ms);
    *err = context_make_error(ctx, "timeout", msg);
    return NULL;
  }

  *err = e;
  return out;
}

static const char* timeout_name(Feature* f) { return ((TimeoutFeature*)f)->name; }
static bool timeout_active(Feature* f) { return ((TimeoutFeature*)f)->active; }
static voxgig_value* timeout_add_options(Feature* f) { return ((TimeoutFeature*)f)->add_opts; }

static void timeout_init(Feature* f, Context* ctx, voxgig_value* options) {
  TimeoutFeature* tf = (TimeoutFeature*)f;
  tf->options = options;
  tf->active = fopt_bool(options, "active", false);
  if (!tf->active) return;

  Utility* util = context_util(ctx);
  TimeoutState* st = (TimeoutState*)calloc(1, sizeof(TimeoutState));
  st->inner = util->fetcher;
  st->options = options;
  st->track = tf->track;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = timeout_fetch;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void timeout_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* timeout_track(Feature* f) {
  TimeoutTrack* t = ((TimeoutFeature*)f)->track;
  return cmap(2, "count", v_num((double)t->count), "ms", v_num((double)t->ms));
}

static const FeatureVT TIMEOUT_VT = {
  timeout_name, timeout_active, timeout_add_options, timeout_init, timeout_hook,
  timeout_track,
};

Feature* feature_timeout_new(void) {
  TimeoutFeature* tf = (TimeoutFeature*)calloc(1, sizeof(TimeoutFeature));
  tf->base.vt = &TIMEOUT_VT;
  tf->name = strdup("timeout");
  tf->active = true; // matches rust default (overridden by init from options)
  tf->add_opts = NULL;
  tf->options = voxgig_new_undef();
  tf->track = (TimeoutTrack*)calloc(1, sizeof(TimeoutTrack));
  return (Feature*)tf;
}
