// Behavioural feature-test harness for the Univec SDK (C port of the
// rust tests/common/mod.rs fh* helpers). Drives each enterprise feature
// through a faithful miniature of the real operation pipeline (same hook
// order + short-circuit rules as the generated entity op code) against a
// configurable mock transport, with no live server and no API-specific
// fixtures. Feature internal state is read through the FeatureVT.track slot
// (feature_track), mirroring the rust `f.track`/state-field assertions.
//
// Header-only; every helper is `static` + unused-safe so a test binary may
// include it and use only part of it.

#ifndef PROJECTNAME_FEATURE_HARNESS_H
#define PROJECTNAME_FEATURE_HARNESS_H

#include "ctest.h" // -> api.h -> sdk.h, plus voxgig_struct.h

#include <ctype.h>
#include <stdio.h>   // snprintf
#include <stdlib.h>
#include <string.h>

#define FH __attribute__((unused)) static

// ---- feature presence -------------------------------------------------------

FH bool fh_has_feature(const char* name) {
  voxgig_value* config = make_config();
  voxgig_value* fm = getp(config, "feature");
  return voxgig_is_map(getp(fm, name));
}

// fh_present("retry,netsim"): true when every comma-separated feature is
// present in this generated SDK (the skip-guard twin of rust fh_present).
FH bool fh_present(const char* csv) {
  char buf[256];
  snprintf(buf, sizeof(buf), "%s", csv);
  char* p = buf;
  while (*p) {
    char* comma = strchr(p, ',');
    if (comma) *comma = '\0';
    while (*p == ' ') p++;
    if (*p && !fh_has_feature(p)) {
      fprintf(stderr, "skip: feature not present in this SDK: %s\n", p);
      return false;
    }
    if (!comma) break;
    p = comma + 1;
  }
  return true;
}

// ---- deterministic virtual clock -------------------------------------------
// now() advances only when sleep(ms) is called, so timing-based features can
// be asserted without real delays. Exposed as voxgig FUNC injectables.

typedef struct {
  int64_t* t;
} FhClock;

FH voxgig_value* fh_clock_now_impl(void* ud, voxgig_value* arg) {
  (void)arg;
  return v_num((double)*(int64_t*)ud);
}
FH voxgig_value* fh_clock_sleep_impl(void* ud, voxgig_value* arg) {
  if (voxgig_is_number(arg)) *(int64_t*)ud += to_int(arg);
  return v_undef();
}
FH FhClock fh_clock_new(void) {
  FhClock c;
  c.t = (int64_t*)calloc(1, sizeof(int64_t));
  return c;
}
FH voxgig_value* fh_now_fn(FhClock* c) { return vfn(fh_clock_now_impl, c->t); }
FH voxgig_value* fh_sleep_fn(FhClock* c) { return vfn(fh_clock_sleep_impl, c->t); }
FH int64_t fh_t(FhClock* c) { return *c->t; }
FH void fh_advance(FhClock* c, int64_t ms) { *c->t += ms; }

// ---- transport-shaped responses --------------------------------------------

// A transport-shaped response the pipeline understands (headers lowercased),
// mirroring rust fh_response.
FH voxgig_value* fh_response(int64_t status, voxgig_value* data, voxgig_value* headers) {
  voxgig_value* h = v_map();
  if (voxgig_is_map(headers)) {
    voxgig_map* hm = voxgig_as_map(headers);
    for (size_t i = 0; i < hm->len; i++) {
      char kb[128];
      snprintf(kb, sizeof(kb), "%s", hm->entries[i].key);
      for (char* k = kb; *k; k++) *k = (char)tolower((unsigned char)*k);
      setp(h, kb, hm->entries[i].value);
    }
  }
  const char* stext = status >= 400 ? "ERR" : "OK";
  return cmap(5, "status", v_num((double)status), "statusText", v_str(stext),
              "body", v_str("not-used"), "json", json_thunk(data), "headers", h);
}

// ---- recording mock transport ----------------------------------------------
// A reply callback: given the 1-based call number and the fetchdef, returns a
// transport-shaped response (or sets *err for a transport-level failure).

typedef voxgig_value* (*FhReplyFn)(void* ud, int64_t n, voxgig_value* fetchdef,
                                   Context* ctx, PNError** err);

typedef struct {
  voxgig_value* calls; // List of { url, fetchdef }
  FhReplyFn reply;     // NULL => default 200 + {ok,n}
  void* reply_ud;
} FhRecorder;

FH voxgig_value* fh_recorder_fetch(Fetcher* self, Context* ctx, const char* url,
                                   voxgig_value* fetchdef, PNError** err) {
  FhRecorder* r = (FhRecorder*)self->state;
  voxgig_list_push(voxgig_as_list(r->calls),
                   cmap(2, "url", v_str(url), "fetchdef", v_share(fetchdef)));
  int64_t n = (int64_t)voxgig_list_len(voxgig_as_list(r->calls));
  if (r->reply) return r->reply(r->reply_ud, n, fetchdef, ctx, err);
  *err = NULL;
  return fh_response(200, cmap(2, "ok", v_bool(true), "n", v_num((double)n)), v_undef());
}

// Build a recording fetcher. *out_calls (if non-NULL) receives the calls list.
FH Fetcher* fh_recorder(FhReplyFn reply, void* reply_ud, voxgig_value** out_calls) {
  FhRecorder* r = (FhRecorder*)calloc(1, sizeof(FhRecorder));
  r->calls = v_list();
  r->reply = reply;
  r->reply_ud = reply_ud;
  Fetcher* fetcher = (Fetcher*)calloc(1, sizeof(Fetcher));
  fetcher->fn = fh_recorder_fetch;
  fetcher->state = r;
  if (out_calls) *out_calls = r->calls;
  return fetcher;
}

// call-record accessors.
FH voxgig_value* rec_call(voxgig_value* calls, int i) {
  return voxgig_getelem(calls, v_int(i), voxgig_new_undef());
}
FH voxgig_value* rec_fetchdef(voxgig_value* calls, int i) {
  return getp(rec_call(calls, i), "fetchdef");
}
FH voxgig_value* rec_headers(voxgig_value* calls, int i) {
  return getp(rec_fetchdef(calls, i), "headers");
}
FH const char* rec_url(voxgig_value* calls, int i) {
  const char* u = get_str(rec_call(calls, i), "url");
  return u ? u : "";
}
FH int rec_count(voxgig_value* calls) {
  return calls ? (int)voxgig_list_len(voxgig_as_list(calls)) : 0;
}

// ---- harness ----------------------------------------------------------------

typedef struct {
  Feature* f;
  voxgig_value* options; // NULL/Noval => just { active: true }
} FhFeat;

typedef struct {
  UnivecSDK* client;
  Utility* utility;
  Context* rootctx;
  const char* base;
} FhHarness;

// fh_make: a real (test-mode) client, an isolated utility whose fetcher is the
// mock server, and the requested features initialised (in order) against it.
// Fires PostConstruct once wiring is complete.
FH FhHarness fh_make(Fetcher* server, FhFeat* feats, size_t nfeats) {
  UnivecSDK* client = test_sdk(NULL, NULL);
  client->features_len = 0; // clear the config-driven features

  Utility* utility = sdk_get_utility(client);
  if (!server) server = fh_recorder(NULL, NULL, NULL);
  utility->fetcher = server;

  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.client = client;
  cs.utility = utility;
  Context* rootctx = make_context_util(cs, sdk_get_root_ctx(client));

  for (size_t i = 0; i < nfeats; i++) {
    voxgig_value* fopts = cmap(1, "active", v_bool(true));
    if (voxgig_is_map(feats[i].options)) {
      voxgig_map* m = voxgig_as_map(feats[i].options);
      for (size_t j = 0; j < m->len; j++) {
        setp(fopts, m->entries[j].key, m->entries[j].value);
      }
    }
    feats[i].f->vt->init(feats[i].f, rootctx, fopts);
    sdk_features_push(client, feats[i].f);
  }

  feature_hook_util(rootctx, "PostConstruct");

  FhHarness h;
  h.client = client;
  h.utility = utility;
  h.rootctx = rootctx;
  h.base = "http://api.test";
  return h;
}

typedef struct {
  const char* entity; // NULL/"" -> "widget"
  const char* op;     // NULL/"" -> "load"
  const char* method; // NULL/"" -> default per op
  const char* path;   // NULL/"" -> "/<entity>"
  voxgig_value* query;
  voxgig_value* headers;
  voxgig_value* body;
  voxgig_value* ctrl;
} FhOpSpec;

typedef struct {
  bool ok;
  voxgig_value* data;
  PNError* err;
  SdkResult* result;
  Context* ctx;
} FhOpResult;

FH const char* fh_default_method(const char* op) {
  if (strcmp(op, "create") == 0) return "POST";
  if (strcmp(op, "update") == 0) return "PATCH";
  if (strcmp(op, "remove") == 0) return "DELETE";
  return "GET";
}

FH char* fh_scalar_str(voxgig_value* v) {
  if (voxgig_is_string(v)) return strdup(voxgig_as_string(v));
  if (voxgig_is_int(v)) {
    char b[32];
    snprintf(b, sizeof(b), "%lld", (long long)voxgig_as_int(v));
    return strdup(b);
  }
  if (voxgig_is_double(v)) {
    double d = voxgig_as_double(v);
    char b[32];
    if (d == (double)(long long)d)
      snprintf(b, sizeof(b), "%lld", (long long)d);
    else
      snprintf(b, sizeof(b), "%g", d);
    return strdup(b);
  }
  if (voxgig_is_bool(v)) return strdup(voxgig_as_bool(v) ? "true" : "false");
  return strdup("");
}

// fh_build_url: base + path + sorted query string (mirrors the rust harness'
// fh_build_url; query values are simple so escaping is unnecessary).
FH char* fh_build_url(Spec* spec) {
  const char* base = spec->base ? spec->base : "";
  const char* path = spec->path ? spec->path : "";
  voxgig_value* query = spec->query;

  const char** keys = NULL;
  size_t nkeys = 0;
  if (voxgig_is_map(query)) {
    voxgig_map* qm = voxgig_as_map(query);
    keys = (const char**)malloc(sizeof(char*) * (qm->len ? qm->len : 1));
    for (size_t i = 0; i < qm->len; i++) {
      voxgig_value* v = qm->entries[i].value;
      if (!v_is_noval(v) && !v_is_null(v)) keys[nkeys++] = qm->entries[i].key;
    }
    for (size_t i = 1; i < nkeys; i++) {
      const char* k = keys[i];
      size_t j = i;
      while (j > 0 && strcmp(keys[j - 1], k) > 0) {
        keys[j] = keys[j - 1];
        j--;
      }
      keys[j] = k;
    }
  }

  char qs[2048];
  qs[0] = '\0';
  size_t ql = 0;
  for (size_t i = 0; i < nkeys; i++) {
    voxgig_value* v = getp(query, keys[i]);
    char* vs = fh_scalar_str(v);
    ql += (size_t)snprintf(qs + ql, sizeof(qs) - ql, "%s%s=%s", i ? "&" : "",
                           keys[i], vs);
    free(vs);
  }
  free((void*)keys);

  char* url = (char*)malloc(strlen(base) + strlen(path) + strlen(qs) + 2);
  if (qs[0])
    sprintf(url, "%s%s?%s", base, path, qs);
  else
    sprintf(url, "%s%s", base, path);
  return url;
}

// Populate ctx.result from the fetched transport value (mirrors rust
// fh_populate_result).
FH void fh_populate_result(Context* ctx, voxgig_value* fetched, PNError* ferr) {
  SdkResult* result = result_new(v_map());
  ctx->result = result;

  if (ferr) {
    result->err = ferr;
    return;
  }
  if (!voxgig_is_map(fetched)) {
    result->err = context_make_error(ctx, "request_no_response", "response: undefined");
    return;
  }

  Response* resp = response_new(fetched);
  result->status = resp->status;
  result->status_text = strdup(resp->status_text ? resp->status_text : "");
  if (voxgig_is_map(resp->headers)) result->headers = resp->headers;
  if (voxgig_is_func(resp->json)) result->body = call_json(resp->json);
  result->resdata = result->body;

  if (result->status >= 400) {
    char msg[256];
    snprintf(msg, sizeof(msg), "request: %lld: %s", (long long)result->status,
             result->status_text);
    result->err = context_make_error(ctx, "request_status", msg);
  }
  if (!result->err) result->ok = true;
}

FH FhOpResult fh_fail(FhHarness* h, Context* ctx, PNError* err) {
  ctx->ctrl->err = err;
  feature_hook_util(ctx, "PreUnexpected");
  FhOpResult r;
  r.ok = false;
  r.data = v_undef();
  r.err = err;
  r.result = ctx->result;
  r.ctx = ctx;
  return r;
}

// fh_op: one operation through the mini pipeline (hook, short-circuit, make*,
// hook, ...), mirroring the generated entity op code.
FH FhOpResult fh_op(FhHarness* h, FhOpSpec o) {
  const char* entity = (o.entity && o.entity[0]) ? o.entity : "widget";
  const char* opname = (o.op && o.op[0]) ? o.op : "load";
  const char* method = (o.method && o.method[0]) ? o.method : fh_default_method(opname);

  voxgig_value* ctrl = voxgig_is_map(o.ctrl) ? o.ctrl : v_map();

  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = opname;
  cs.ctrl = ctrl;
  Context* ctx = make_context_util(cs, h->rootctx);
  ctx->op = operation_new(cmap(2, "entity", v_str(entity), "name", v_str(opname)));

  Utility* util = context_util(ctx);

  feature_hook_util(ctx, "PostConstructEntity");

  feature_hook_util(ctx, "PrePoint");
  if (ctx->out_point_kind == OUT_ERR) {
    return fh_fail(h, ctx, ctx->out_point_err);
  }

  feature_hook_util(ctx, "PreSpec");

  char pathbuf[256];
  const char* path = (o.path && o.path[0]) ? o.path : NULL;
  if (!path) {
    snprintf(pathbuf, sizeof(pathbuf), "/%s", entity);
    path = pathbuf;
  }

  voxgig_value* headers = v_map();
  if (voxgig_is_map(o.headers)) {
    voxgig_map* m = voxgig_as_map(o.headers);
    for (size_t i = 0; i < m->len; i++) setp(headers, m->entries[i].key, m->entries[i].value);
  }
  voxgig_value* query = v_map();
  if (voxgig_is_map(o.query)) {
    voxgig_map* m = voxgig_as_map(o.query);
    for (size_t i = 0; i < m->len; i++) setp(query, m->entries[i].key, m->entries[i].value);
  }

  voxgig_value* specmap = cmap(6, "method", v_str(method), "base", v_str(h->base),
                               "path", v_str(path), "headers", headers, "query", query,
                               "step", v_str("start"));
  Spec* spec = spec_new(specmap);
  if (o.body && !v_is_noval(o.body)) spec->body = o.body;
  ctx->spec = spec;

  feature_hook_util(ctx, "PreRequest");

  char* url = fh_build_url(spec);
  spec_set_url(spec, url);

  voxgig_value* fetchdef = cmap(3, "url", v_str(url), "method", v_str(spec->method),
                                "headers", v_share(spec->headers));
  if (spec->body && !v_is_noval(spec->body)) setp(fetchdef, "body", v_share(spec->body));

  PNError* ferr = NULL;
  voxgig_value* fetched = utility_fetch(util, ctx, url, fetchdef, &ferr);
  free(url);

  if (!ferr && voxgig_is_map(fetched)) {
    ctx->response = response_new(fetched);
  }

  feature_hook_util(ctx, "PreResponse");
  fh_populate_result(ctx, fetched, ferr);
  feature_hook_util(ctx, "PreResult");
  feature_hook_util(ctx, "PreDone");

  SdkResult* result = ctx->result;
  if (result && result->ok) {
    FhOpResult r;
    r.ok = true;
    r.data = v_share(result->resdata);
    r.err = NULL;
    r.result = result;
    r.ctx = ctx;
    return r;
  }

  PNError* err = (result && result->err) ? result->err
                                         : context_make_error(ctx, "op_failed", "operation failed");
  return fh_fail(h, ctx, err);
}

FH const char* fh_err_code(PNError* err) {
  return (err && err->code) ? err->code : "";
}

// Convenience: read an int64 counter out of a feature_track() snapshot map.
FH int64_t fh_track_int(Feature* f, const char* key) {
  voxgig_value* t = feature_track(f);
  return to_int(getp(t, key));
}

#endif // PROJECTNAME_FEATURE_HARNESS_H
