// Distributed-tracing telemetry (mirrors feature/telemetry.rs). Opens a span
// per operation (PrePoint), propagates trace context to the server as W3C
// `traceparent` plus `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and
// closes the span on completion (PreDone) or failure (PreUnexpected). Each
// span closes exactly once (the per-context marker in ctx.out is consumed on
// close). Finished spans accumulate on the feature; an `exporter` callback,
// when provided, is invoked with each finished span. Trace/span id generation
// (`idgen`) and the clock (`now`) are injectable for deterministic tests.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char TELEMETRY_SPAN_KEY[] = "telemetry_span";

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  int64_t seq;

  // Activity tracking (mirrors the ts client._telemetry record).
  voxgig_value* spans; // List
  int64_t active_spans;
} TelemetryFeature;

// Generate a trace/span id. Uses the injectable `idgen` when supplied; else a
// deterministic-ish sequential id unique within a client instance. Returns a
// malloc'd string (caller frees).
static char* telemetry_id(TelemetryFeature* tf, const char* kind) {
  voxgig_value* idgen = getp(tf->options, "idgen");
  if (voxgig_is_func(idgen)) {
    voxgig_value* r = call_vfn(idgen, v_str(kind));
    if (voxgig_is_string(r)) {
      return strdup(voxgig_as_string(r));
    }
  }

  tf->seq += 1;
  char n[64];
  snprintf(n, sizeof(n), "%04llx", (unsigned long long)tf->seq);
  size_t len = strlen(n);
  while (len < 16) {
    n[len] = '0';
    len++;
  }
  n[len] = '\0';
  const char* prefix = (strcmp(kind, "trace") == 0) ? "t" : "s";
  char out[80];
  snprintf(out, sizeof(out), "%s%s", prefix, n);
  return strdup(out);
}

// Read + consume the ctx.out span marker (mirrors rust ctx.out_take). setp
// with undef erases the key, so a second close finds nothing.
static voxgig_value* out_take(Context* ctx, const char* key) {
  voxgig_value* v = ctx_out_extra_get(ctx, key);
  ctx_out_extra_set(ctx, key, voxgig_new_undef());
  return v;
}

static void telemetry_close(TelemetryFeature* tf, Context* ctx, bool ok) {
  // Close once per operation; a PreDone followed by a pipeline failure
  // (non-2xx) fires PreUnexpected too, which then finds no open span.
  voxgig_value* span = out_take(ctx, TELEMETRY_SPAN_KEY);
  if (!voxgig_is_map(span)) return;

  int64_t end = fopt_now_call(tf->options);
  int64_t start = 0;
  get_i64(span, "start", &start);
  int64_t dur = end - start;
  if (dur < 0) dur = 0;
  setp(span, "end", v_num((double)end));
  setp(span, "durationMs", v_num((double)dur));
  setp(span, "ok", v_bool(ok));

  tf->active_spans -= 1;
  voxgig_list_push(voxgig_as_list(tf->spans), voxgig_retain(span));

  voxgig_value* exporter = getp(tf->options, "exporter");
  if (voxgig_is_func(exporter)) {
    call_vfn(exporter, span);
  }
}

static const char* telemetry_name(Feature* f) { return ((TelemetryFeature*)f)->name; }
static bool telemetry_active(Feature* f) { return ((TelemetryFeature*)f)->active; }
static voxgig_value* telemetry_add_options(Feature* f) {
  return ((TelemetryFeature*)f)->add_opts;
}

static void telemetry_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  TelemetryFeature* tf = (TelemetryFeature*)f;
  tf->options = options;
  tf->active = fopt_bool(options, "active", false);
  tf->seq = 0;
}

static void telemetry_pre_point(TelemetryFeature* tf, Context* ctx) {
  if (!tf->active) return;

  const char* entity = ctx->op->entity;
  const char* opname = ctx->op->name;

  voxgig_value* span = voxgig_new_map();
  char* trace = telemetry_id(tf, "trace");
  setp(span, "traceId", v_str(trace));
  free(trace);
  char* spanid = telemetry_id(tf, "span");
  setp(span, "spanId", v_str(spanid));
  free(spanid);

  size_t nl = strlen(entity) + strlen(opname) + 2; // '.' + '\0'
  char* namebuf = (char*)malloc(nl);
  snprintf(namebuf, nl, "%s.%s", entity, opname);
  setp(span, "name", v_str(namebuf));
  free(namebuf);

  setp(span, "start", v_num((double)fopt_now_call(tf->options)));
  ctx_out_extra_set(ctx, TELEMETRY_SPAN_KEY, span);
  tf->active_spans += 1;
}

static void telemetry_pre_request(TelemetryFeature* tf, Context* ctx) {
  if (!tf->active) return;

  voxgig_value* span = ctx_out_extra_get(ctx, TELEMETRY_SPAN_KEY);
  if (!voxgig_is_map(span) || !ctx->spec) return;

  voxgig_value* headers = ctx->spec->headers;
  if (!voxgig_is_map(headers)) {
    headers = voxgig_new_map();
    ctx->spec->headers = headers;
  }

  voxgig_value* h = fopt_map(tf->options, "headers");
  const char* trace_id = get_str(span, "traceId");
  if (!trace_id) trace_id = "";
  const char* span_id = get_str(span, "spanId");
  if (!span_id) span_id = "";

  setp(headers, fopt_str(h, "trace", "X-Trace-Id"), v_str(trace_id));
  setp(headers, fopt_str(h, "span", "X-Span-Id"), v_str(span_id));

  size_t tl = strlen(trace_id) + strlen(span_id) + 8; // "00-" "-" "-01" + '\0'
  char* tp = (char*)malloc(tl);
  snprintf(tp, tl, "00-%s-%s-01", trace_id, span_id);
  setp(headers, fopt_str(h, "parent", "traceparent"), v_str(tp));
  free(tp);
}

static void telemetry_pre_done(TelemetryFeature* tf, Context* ctx) {
  bool ok = false;
  if (ctx->result) {
    ok = ctx->result->ok && ctx->result->err == NULL;
  }
  telemetry_close(tf, ctx, ok);
}

static void telemetry_pre_unexpected(TelemetryFeature* tf, Context* ctx) {
  telemetry_close(tf, ctx, false);
}

static void telemetry_hook(Feature* f, const char* name, Context* ctx) {
  TelemetryFeature* tf = (TelemetryFeature*)f;
  if (strcmp(name, "PrePoint") == 0) {
    telemetry_pre_point(tf, ctx);
  } else if (strcmp(name, "PreRequest") == 0) {
    telemetry_pre_request(tf, ctx);
  } else if (strcmp(name, "PreDone") == 0) {
    telemetry_pre_done(tf, ctx);
  } else if (strcmp(name, "PreUnexpected") == 0) {
    telemetry_pre_unexpected(tf, ctx);
  }
}

static voxgig_value* telemetry_track(Feature* f) {
  TelemetryFeature* tf = (TelemetryFeature*)f;
  int64_t nspans = (int64_t)voxgig_list_len(voxgig_as_list(tf->spans));
  return cmap(2, "spans", v_num((double)nspans),
              "active", v_num((double)tf->active_spans));
}

static const FeatureVT TELEMETRY_VT = {
  telemetry_name, telemetry_active, telemetry_add_options, telemetry_init, telemetry_hook,
  telemetry_track,
};

Feature* feature_telemetry_new(void) {
  TelemetryFeature* tf = (TelemetryFeature*)calloc(1, sizeof(TelemetryFeature));
  tf->base.vt = &TELEMETRY_VT;
  tf->name = strdup("telemetry");
  tf->active = true; // matches rust new() (overridden by init from options)
  tf->add_opts = NULL;
  tf->options = voxgig_new_undef();
  tf->seq = 0;
  tf->spans = voxgig_new_list();
  tf->active_spans = 0;
  return (Feature*)tf;
}
