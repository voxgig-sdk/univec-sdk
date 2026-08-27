// Statistics capture (mirrors feature/metrics.rs). Records per-operation
// counters and latency for every call: totals plus a breakdown keyed by
// `<entity>.<op>`. Timing starts at endpoint resolution (PrePoint) and stops
// when the call returns (PreDone) or fails (PreUnexpected); each operation is
// recorded exactly once (the per-context start marker in ctx.out is consumed
// on record). The clock is injectable (`now`) for deterministic tests.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

#define METRICS_START_KEY "metrics_start"

typedef struct {
  int64_t count;
  int64_t ok;
  int64_t err;
  int64_t total_ms;
  int64_t max_ms;
} MetricsBucket;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  // Aggregates (mirrors the ts client._metrics record).
  MetricsBucket total;
  // ops HashMap<String, MetricsBucket> as parallel growable arrays.
  char** op_keys;
  MetricsBucket* op_buckets;
  size_t ops_len;
  size_t ops_cap;
} MetricsFeature;

static void bump(MetricsBucket* bucket, bool ok, int64_t dur) {
  bucket->count += 1;
  if (ok) {
    bucket->ok += 1;
  } else {
    bucket->err += 1;
  }
  bucket->total_ms += dur;
  if (dur > bucket->max_ms) {
    bucket->max_ms = dur;
  }
}

// ops.entry(key).or_default(): find or insert a zeroed bucket for key.
static MetricsBucket* ops_entry(MetricsFeature* mf, const char* key) {
  for (size_t i = 0; i < mf->ops_len; i++) {
    if (strcmp(mf->op_keys[i], key) == 0) return &mf->op_buckets[i];
  }
  if (mf->ops_len == mf->ops_cap) {
    size_t nc = mf->ops_cap ? mf->ops_cap * 2 : 8;
    mf->op_keys = (char**)realloc(mf->op_keys, nc * sizeof(char*));
    mf->op_buckets = (MetricsBucket*)realloc(mf->op_buckets, nc * sizeof(MetricsBucket));
    mf->ops_cap = nc;
  }
  mf->op_keys[mf->ops_len] = strdup(key);
  memset(&mf->op_buckets[mf->ops_len], 0, sizeof(MetricsBucket));
  return &mf->op_buckets[mf->ops_len++];
}

static char* dot_join(const char* a, const char* b) {
  size_t na = a ? strlen(a) : 0;
  size_t nb = b ? strlen(b) : 0;
  char* s = (char*)malloc(na + nb + 2);
  memcpy(s, a ? a : "", na);
  s[na] = '.';
  memcpy(s + na + 1, b ? b : "", nb);
  s[na + 1 + nb] = '\0';
  return s;
}

static void metrics_record(MetricsFeature* mf, Context* ctx, bool ok) {
  // Record once per operation: the missing start marker makes a second call
  // (PreDone followed by PreUnexpected on failure) a no-op.
  voxgig_value* start_v = ctx_out_extra_get(ctx, METRICS_START_KEY);
  if (!voxgig_is_number(start_v)) {
    // "other" branch: put anything unexpected back (a no-op here) and return.
    return;
  }
  int64_t start = to_int(start_v);
  // Consume the marker.
  ctx_out_extra_set(ctx, METRICS_START_KEY, v_undef());

  int64_t dur = fopt_now_call(mf->options) - start;
  if (dur < 0) dur = 0;

  const char* entity = ctx->op->entity;
  const char* opname = ctx->op->name;
  char* key = dot_join(entity, opname);

  bump(&mf->total, ok, dur);
  bump(ops_entry(mf, key), ok, dur);
}

static void metrics_pre_point(MetricsFeature* mf, Context* ctx) {
  if (!mf->active) {
    return;
  }
  ctx_out_extra_set(ctx, METRICS_START_KEY, v_num((double)fopt_now_call(mf->options)));
}

static void metrics_pre_done(MetricsFeature* mf, Context* ctx) {
  // Classify by the actual result: a 4xx/5xx that flows through still reaches
  // PreDone before the pipeline errors.
  bool ok = ctx->result ? (ctx->result->ok && ctx->result->err == NULL) : false;
  metrics_record(mf, ctx, ok);
}

static void metrics_pre_unexpected(MetricsFeature* mf, Context* ctx) {
  metrics_record(mf, ctx, false);
}

static const char* metrics_name(Feature* f) { return ((MetricsFeature*)f)->name; }
static bool metrics_active(Feature* f) { return ((MetricsFeature*)f)->active; }
static voxgig_value* metrics_add_options(Feature* f) { return ((MetricsFeature*)f)->add_opts; }

static void metrics_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  MetricsFeature* mf = (MetricsFeature*)f;
  mf->options = options;
  mf->active = fopt_bool(options, "active", false);
  memset(&mf->total, 0, sizeof(MetricsBucket));
  mf->ops_len = 0; // reset to an empty HashMap
}

static void metrics_hook(Feature* f, const char* name, Context* ctx) {
  MetricsFeature* mf = (MetricsFeature*)f;
  if (strcmp(name, "PrePoint") == 0) {
    metrics_pre_point(mf, ctx);
  } else if (strcmp(name, "PreDone") == 0) {
    metrics_pre_done(mf, ctx);
  } else if (strcmp(name, "PreUnexpected") == 0) {
    metrics_pre_unexpected(mf, ctx);
  }
}

static voxgig_value* bucket_value(const MetricsBucket* b) {
  return cmap(5, "count", v_num((double)b->count), "ok", v_num((double)b->ok),
              "err", v_num((double)b->err), "totalMs", v_num((double)b->total_ms),
              "maxMs", v_num((double)b->max_ms));
}

static voxgig_value* metrics_track(Feature* f) {
  MetricsFeature* mf = (MetricsFeature*)f;
  voxgig_value* ops = v_map();
  for (size_t i = 0; i < mf->ops_len; i++) {
    setp(ops, mf->op_keys[i], bucket_value(&mf->op_buckets[i]));
  }
  return cmap(2, "total", bucket_value(&mf->total), "ops", ops);
}

static const FeatureVT METRICS_VT = {
  metrics_name, metrics_active, metrics_add_options, metrics_init, metrics_hook,
  metrics_track,
};

Feature* feature_metrics_new(void) {
  MetricsFeature* mf = (MetricsFeature*)calloc(1, sizeof(MetricsFeature));
  mf->base.vt = &METRICS_VT;
  mf->name = strdup("metrics");
  mf->active = true;
  mf->add_opts = NULL;
  mf->options = voxgig_new_undef();
  memset(&mf->total, 0, sizeof(MetricsBucket));
  mf->op_keys = NULL;
  mf->op_buckets = NULL;
  mf->ops_len = 0;
  mf->ops_cap = 0;
  return (Feature*)mf;
}
