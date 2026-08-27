// Automatic retry with exponential backoff + jitter (mirrors feature/
// retry.rs). Wraps the active transport in init; a Retry-After header
// overrides the computed backoff. All features inactive by default.

#include "sdk.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int64_t attempts;
  voxgig_value* retries; // List of attempt records
} RetryTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  RetryTrack* track;
} RetryFeature;

typedef struct {
  Fetcher* inner;
  voxgig_value* options;
  RetryTrack* track;
} RetryState;

static bool retryable(voxgig_value* options, voxgig_value* out, PNError* e) {
  if (e) return true;
  if (v_is_noval(out) || v_is_null(out)) return true;
  int64_t status;
  if (!fres_status(out, &status)) return false;

  voxgig_value* sl = fopt_list(options, "statuses");
  if (voxgig_is_list(sl)) {
    voxgig_list* l = voxgig_as_list(sl);
    for (size_t i = 0; i < l->len; i++) {
      if (voxgig_is_number(l->items[i]) && to_int(l->items[i]) == status) return true;
    }
    return false;
  }
  static const int64_t DEF[] = {408, 425, 429, 500, 502, 503, 504};
  for (size_t i = 0; i < sizeof(DEF) / sizeof(DEF[0]); i++) {
    if (DEF[i] == status) return true;
  }
  return false;
}

static bool retry_after(voxgig_value* res, int64_t* out) {
  const char* v = fres_header(res, "retry-after");
  if (!v) return false;
  int64_t seconds = fparse_int(v, -1);
  if (seconds < 0) return false;
  *out = seconds * 1000;
  return true;
}

static int64_t backoff(voxgig_value* options, voxgig_value* out, PNError* e, int64_t attempt,
                       int64_t min_delay, int64_t max_delay, double factor) {
  if (!e) {
    int64_t ra;
    if (retry_after(out, &ra)) {
      return ra < max_delay ? ra : max_delay;
    }
  }
  double base = (double)min_delay * pow(factor, (double)attempt);
  int64_t jitter = (fopt_bool(options, "jitter", true) && min_delay > 0) ? rand_int(min_delay) : 0;
  int64_t wait = (int64_t)base + jitter;
  return wait < max_delay ? wait : max_delay;
}

static void track_attempt(RetryTrack* track, int64_t attempt, voxgig_value* out, PNError* e,
                          int64_t wait) {
  track->attempts += 1;
  voxgig_value* entry = voxgig_new_map();
  setp(entry, "attempt", v_num((double)attempt));
  setp(entry, "wait", v_num((double)wait));
  if (!e) {
    int64_t status;
    if (fres_status(out, &status)) setp(entry, "status", v_num((double)status));
  } else {
    setp(entry, "error", v_str(e->msg));
  }
  voxgig_list_push(voxgig_as_list(track->retries), entry);
}

static voxgig_value* retry_fetch(Fetcher* self, Context* ctx, const char* url,
                                 voxgig_value* fetchdef, PNError** err) {
  RetryState* st = (RetryState*)self->state;
  voxgig_value* options = st->options;

  int64_t max = fopt_int(options, "retries", 2);
  int64_t min_delay = fopt_int(options, "minDelay", 50);
  int64_t max_delay = fopt_int(options, "maxDelay", 2000);
  double factor = fopt_num(options, "factor", 2.0);

  int64_t attempt = 0;
  while (1) {
    PNError* e = NULL;
    voxgig_value* out = st->inner->fn(st->inner, ctx, url, fetchdef, &e);

    if (!retryable(options, out, e) || attempt >= max) {
      *err = e;
      return out;
    }

    int64_t wait = backoff(options, out, e, attempt, min_delay, max_delay, factor);
    track_attempt(st->track, attempt + 1, out, e, wait);
    if (wait > 0) fopt_sleep_call(options, wait);
    attempt++;
  }
}

static const char* retry_name(Feature* f) { return ((RetryFeature*)f)->name; }
static bool retry_active(Feature* f) { return ((RetryFeature*)f)->active; }
static voxgig_value* retry_add_options(Feature* f) { return ((RetryFeature*)f)->add_opts; }

static void retry_init(Feature* f, Context* ctx, voxgig_value* options) {
  RetryFeature* rf = (RetryFeature*)f;
  rf->options = options;
  rf->active = fopt_bool(options, "active", false);
  if (!rf->active) return;

  Utility* util = context_util(ctx);
  RetryState* st = (RetryState*)calloc(1, sizeof(RetryState));
  st->inner = util->fetcher;
  st->options = options;
  st->track = rf->track;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = retry_fetch;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void retry_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* retry_track(Feature* f) {
  RetryTrack* t = ((RetryFeature*)f)->track;
  return cmap(1, "attempts", v_num((double)t->attempts));
}

static const FeatureVT RETRY_VT = {
  retry_name, retry_active, retry_add_options, retry_init, retry_hook,
  retry_track,
};

Feature* feature_retry_new(void) {
  RetryFeature* rf = (RetryFeature*)calloc(1, sizeof(RetryFeature));
  rf->base.vt = &RETRY_VT;
  rf->name = strdup("retry");
  rf->active = true; // matches rust default (overridden by init from options)
  rf->add_opts = NULL;
  rf->options = voxgig_new_undef();
  rf->track = (RetryTrack*)calloc(1, sizeof(RetryTrack));
  rf->track->attempts = 0;
  rf->track->retries = voxgig_new_list();
  return (Feature*)rf;
}
