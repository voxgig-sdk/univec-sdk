// Request/response capture for debugging (mirrors feature/debug.rs). Records a
// bounded ring buffer of per-operation traces — method, URL, redacted headers,
// response status and timing — on the feature's entries. Sensitive header
// values (matching `redact`, default authorization/cookie/api-key style names)
// are masked. An optional `onEntry` callback receives each finished entry.
// `max` caps the buffer (default 100).

#include "sdk.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define DEBUG_ENTRY_KEY "debug_entry"

static const char* DEBUG_DEFAULT_REDACT[] = {
  "authorization",
  "cookie",
  "set-cookie",
  "api-key",
  "apikey",
  "x-api-key",
  "idempotency-key",
};
#define DEBUG_DEFAULT_REDACT_LEN (sizeof(DEBUG_DEFAULT_REDACT) / sizeof(DEBUG_DEFAULT_REDACT[0]))

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  // Activity tracking (mirrors the ts client._debug record).
  voxgig_value* entries; // List of Value
} DebugFeature;

// True when lowercase(key) == pat (pat compared as-is, mirroring rust
// `k.to_lowercase() == *p`).
static bool eq_lower(const char* key, const char* pat) {
  size_t i = 0;
  for (; key[i] != '\0' && pat[i] != '\0'; i++) {
    if ((char)tolower((unsigned char)key[i]) != pat[i]) return false;
  }
  return key[i] == '\0' && pat[i] == '\0';
}

// patterns = fopt_str_list(options,"redact") or DEBUG_DEFAULT_REDACT.
static bool is_redacted(DebugFeature* df, const char* key) {
  voxgig_value* rl = getp(df->options, "redact");
  if (voxgig_is_list(rl)) {
    voxgig_list* l = voxgig_as_list(rl);
    for (size_t i = 0; i < l->len; i++) {
      voxgig_value* pv = l->items[i];
      if (voxgig_is_string(pv) && eq_lower(key, voxgig_as_string(pv))) return true;
    }
    return false;
  }
  for (size_t i = 0; i < DEBUG_DEFAULT_REDACT_LEN; i++) {
    if (eq_lower(key, DEBUG_DEFAULT_REDACT[i])) return true;
  }
  return false;
}

static voxgig_value* debug_redact(DebugFeature* df, voxgig_value* headers) {
  voxgig_value* out = v_map();
  if (voxgig_is_map(headers)) {
    voxgig_map* m = voxgig_as_map(headers);
    for (size_t i = 0; i < m->len; i++) {
      const char* k = m->entries[i].key;
      if (is_redacted(df, k)) {
        setp(out, k, v_str("<redacted>"));
      } else {
        setp(out, k, m->entries[i].value); // v.clone(): setp retains
      }
    }
  }
  return out;
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

static void debug_finish(DebugFeature* df, Context* ctx, bool ok) {
  // Finish once per operation: the marker in ctx.out is consumed here.
  voxgig_value* entry = ctx_out_extra_get(ctx, DEBUG_ENTRY_KEY);
  if (!voxgig_is_map(entry)) {
    return;
  }
  ctx_out_extra_set(ctx, DEBUG_ENTRY_KEY, v_undef()); // out_take

  bool result_ok = ctx->result ? ctx->result->ok : true;
  setp(entry, "ok", v_bool(ok && result_ok));

  int64_t start = 0;
  get_i64(entry, "start", &start); // unwrap_or(0)
  int64_t dur = fopt_now_call(df->options) - start;
  if (dur < 0) dur = 0;
  setp(entry, "durationMs", v_num((double)dur));

  if (v_is_noval(getp(entry, "status"))) {
    if (ctx->result) {
      setp(entry, "status", v_num((double)ctx->result->status));
    }
  }

  voxgig_list_push(voxgig_as_list(df->entries), voxgig_retain(entry));
  int64_t max = fopt_int(df->options, "max", 100);
  while (voxgig_list_len(voxgig_as_list(df->entries)) > (size_t)max) {
    voxgig_list_erase(voxgig_as_list(df->entries), 0);
  }

  voxgig_value* on_entry = getp(df->options, "onEntry");
  if (voxgig_is_func(on_entry)) {
    call_vfn(on_entry, entry);
  }
}

static void debug_pre_request(DebugFeature* df, Context* ctx) {
  if (!df->active) {
    return;
  }

  const char* entity = ctx->op->entity;
  const char* opname = ctx->op->name;

  voxgig_value* entry = v_map();
  char* op = dot_join(entity, opname);
  setp(entry, "op", v_str(op));
  setp(entry, "start", v_num((double)fopt_now_call(df->options)));
  if (ctx->spec) {
    Spec* s = ctx->spec;
    setp(entry, "method", v_str(s->method ? s->method : ""));
    if (s->url && s->url[0] != '\0') {
      setp(entry, "url", v_str(s->url));
    } else {
      setp(entry, "url", v_str(s->path ? s->path : ""));
    }
    setp(entry, "headers", debug_redact(df, s->headers));
  }
  ctx_out_extra_set(ctx, DEBUG_ENTRY_KEY, entry);
}

static void debug_pre_response(DebugFeature* df, Context* ctx) {
  if (!df->active) {
    return;
  }

  voxgig_value* entry = ctx_out_extra_get(ctx, DEBUG_ENTRY_KEY);
  if (!voxgig_is_map(entry)) {
    return;
  }
  if (ctx->response) {
    setp(entry, "status", v_num((double)ctx->response->status));
    const char* url = get_str(entry, "url");
    if (!url || url[0] == '\0') {
      if (ctx->spec) {
        setp(entry, "url", v_str(ctx->spec->url ? ctx->spec->url : ""));
      }
    }
  }
}

static void debug_pre_done(DebugFeature* df, Context* ctx) {
  debug_finish(df, ctx, true);
}

static void debug_pre_unexpected(DebugFeature* df, Context* ctx) {
  voxgig_value* entry = ctx_out_extra_get(ctx, DEBUG_ENTRY_KEY);
  if (voxgig_is_map(entry)) {
    if (ctx->ctrl && ctx->ctrl->err) {
      setp(entry, "error", v_str(ctx->ctrl->err->msg ? ctx->ctrl->err->msg : ""));
    }
  }
  debug_finish(df, ctx, false);
}

static const char* debug_name(Feature* f) { return ((DebugFeature*)f)->name; }
static bool debug_active(Feature* f) { return ((DebugFeature*)f)->active; }
static voxgig_value* debug_add_options(Feature* f) { return ((DebugFeature*)f)->add_opts; }

static void debug_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  DebugFeature* df = (DebugFeature*)f;
  df->options = options;
  df->active = fopt_bool(options, "active", false);
}

static void debug_hook(Feature* f, const char* name, Context* ctx) {
  DebugFeature* df = (DebugFeature*)f;
  if (strcmp(name, "PreRequest") == 0) {
    debug_pre_request(df, ctx);
  } else if (strcmp(name, "PreResponse") == 0) {
    debug_pre_response(df, ctx);
  } else if (strcmp(name, "PreDone") == 0) {
    debug_pre_done(df, ctx);
  } else if (strcmp(name, "PreUnexpected") == 0) {
    debug_pre_unexpected(df, ctx);
  }
}

static voxgig_value* debug_track(Feature* f) {
  DebugFeature* df = (DebugFeature*)f;
  int64_t n = (int64_t)voxgig_list_len(voxgig_as_list(df->entries));
  return cmap(1, "entries", v_num((double)n));
}

static const FeatureVT DEBUG_VT = {
  debug_name, debug_active, debug_add_options, debug_init, debug_hook,
  debug_track,
};

Feature* feature_debug_new(void) {
  DebugFeature* df = (DebugFeature*)calloc(1, sizeof(DebugFeature));
  df->base.vt = &DEBUG_VT;
  df->name = strdup("debug");
  df->active = true;
  df->add_opts = NULL;
  df->options = voxgig_new_undef();
  df->entries = voxgig_new_list();
  return (Feature*)df;
}
