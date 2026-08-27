// Streaming result support (mirrors feature/streaming.rs, a synchronous
// runtime). For list-style operations it attaches a `result.stream` producer
// so callers can consume items incrementally instead of materialising the
// whole list themselves. A `chunkSize` groups items into list batches when
// set; a `chunkDelay` (ms) paces delivery via the injectable `sleep` for
// offline tests.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  // Activity tracking (mirrors the ts client._streaming record).
  int64_t opened;
} StreamingFeature;

// Heap ud for the stream producer closure: captures the options and the
// result whose resdata is read lazily on each call. The rust version uses a
// Weak reference to avoid an Rc cycle; C is never-free, so we hold the
// SdkResult pointer directly (leaks are acceptable).
typedef struct {
  voxgig_value* options;
  SdkResult* result;
} StreamUd;

// True when opname is in the configured "ops" list (default ["list"]).
static bool streamable_op(voxgig_value* options, const char* opname) {
  voxgig_value* ops = fopt_list(options, "ops");
  if (voxgig_is_list(ops)) {
    voxgig_list* l = voxgig_as_list(ops);
    for (size_t i = 0; i < l->len; i++) {
      voxgig_value* v = l->items[i];
      if (voxgig_is_string(v) && strcmp(voxgig_as_string(v), opname) == 0) return true;
    }
    return false;
  }
  return strcmp(opname, "list") == 0;
}

// Produce the (possibly chunked, possibly paced) list of items from resdata.
static voxgig_value* iterate(voxgig_value* options, voxgig_value* resdata) {
  int64_t chunk_delay = fopt_int(options, "chunkDelay", 0);
  int64_t chunk_size = fopt_int(options, "chunkSize", 0);

  voxgig_list* items = NULL;
  size_t nitems = 0;
  if (voxgig_is_list(resdata)) {
    items = voxgig_as_list(resdata);
    nitems = items->len;
  }

  voxgig_value* out = voxgig_new_list();

  if (chunk_size > 0) {
    size_t i = 0;
    while (i < nitems) {
      if (chunk_delay > 0) fopt_sleep_call(options, chunk_delay);
      size_t end = i + (size_t)chunk_size;
      if (end > nitems) end = nitems;
      voxgig_value* chunk = voxgig_new_list();
      for (size_t j = i; j < end; j++) {
        voxgig_list_push(voxgig_as_list(chunk), voxgig_retain(items->items[j]));
      }
      voxgig_list_push(voxgig_as_list(out), chunk);
      i = end;
    }
    return out;
  }

  for (size_t i = 0; i < nitems; i++) {
    if (chunk_delay > 0) fopt_sleep_call(options, chunk_delay);
    voxgig_list_push(voxgig_as_list(out), voxgig_retain(items->items[i]));
  }
  return out;
}

// The stream producer attached to the result (StreamFn). Reads resdata at
// call time, mirroring the rust closure that upgrades the weak result then
// reads `resdata`.
static voxgig_value* streaming_stream(void* ud) {
  StreamUd* s = (StreamUd*)ud;
  voxgig_value* resdata = s->result->resdata;
  return iterate(s->options, resdata);
}

static const char* streaming_name(Feature* f) { return ((StreamingFeature*)f)->name; }
static bool streaming_active(Feature* f) { return ((StreamingFeature*)f)->active; }
static voxgig_value* streaming_add_options(Feature* f) {
  return ((StreamingFeature*)f)->add_opts;
}

static void streaming_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  StreamingFeature* sf = (StreamingFeature*)f;
  sf->options = options;
  sf->active = fopt_bool(options, "active", false);
}

static void streaming_pre_result(StreamingFeature* sf, Context* ctx) {
  if (!sf->active || !streamable_op(sf->options, ctx->op->name)) return;
  if (!ctx->result) return;

  StreamUd* ud = (StreamUd*)calloc(1, sizeof(StreamUd));
  ud->options = sf->options;
  ud->result = ctx->result;

  ctx->result->streaming = true;
  ctx->result->stream = streaming_stream;
  ctx->result->stream_ud = ud;

  sf->opened += 1;
}

static void streaming_hook(Feature* f, const char* name, Context* ctx) {
  StreamingFeature* sf = (StreamingFeature*)f;
  if (strcmp(name, "PreResult") == 0) {
    streaming_pre_result(sf, ctx);
  }
}

static voxgig_value* streaming_track(Feature* f) {
  StreamingFeature* sf = (StreamingFeature*)f;
  return cmap(1, "opened", v_num((double)sf->opened));
}

static const FeatureVT STREAMING_VT = {
  streaming_name, streaming_active, streaming_add_options, streaming_init, streaming_hook,
  streaming_track,
};

Feature* feature_streaming_new(void) {
  StreamingFeature* sf = (StreamingFeature*)calloc(1, sizeof(StreamingFeature));
  sf->base.vt = &STREAMING_VT;
  sf->name = strdup("streaming");
  sf->active = true; // matches rust new() (overridden by init from options)
  sf->add_opts = NULL;
  sf->options = voxgig_new_undef();
  sf->opened = 0;
  return (Feature*)sf;
}
