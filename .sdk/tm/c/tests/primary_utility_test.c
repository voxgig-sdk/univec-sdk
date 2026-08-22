// Primary utility tests (C port of tm/rust/tests/primary_utility_test.rs).
// The rust suite drives the shared `primary` subtree of ../.sdk/test/test.json
// through the pipeline utilities; the C port exercises the same utility surface
// with deterministic, directly-constructed contexts (one focused unit test per
// utility) so every make_*/prepare_*/result_*/transform_*/feature_* entry point
// is covered.

#include "feature_harness.h" // fh_response + Fetcher helpers + ctest.h

#include <stdio.h>

static int TESTS = 0;
#define RUN(fn)                                                                 \
  do {                                                                         \
    TESTS++;                                                                   \
    fn();                                                                      \
  } while (0)

static UnivecSDK* C;
static Utility* U;

static void base_client(void) {
  C = test_sdk(v_undef(), v_undef());
  U = sdk_get_utility(C);
}

static Context* test_ctx(void) {
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = C;
  cs.utility = U;
  return make_context_util(cs, sdk_get_root_ctx(C));
}

static Context* ctx_named(const char* opname) {
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = opname;
  cs.client = C;
  cs.utility = U;
  return make_context_util(cs, sdk_get_root_ctx(C));
}

static Context* full_ctx(void) {
  Context* ctx = test_ctx();
  ctx->point = cmap(7, "parts", clist(2, v_str("items"), v_str("{id}")),
                    "args", cmap(1, "params",
                                 clist(1, cmap(2, "name", v_str("id"), "reqd", v_bool(true)))),
                    "params", clist(1, v_str("id")),
                    "alias", v_map(), "select", v_map(), "active", v_bool(true),
                    "transform", v_map());
  ctx->mtch = cmap(1, "id", v_str("item01"));
  ctx->reqmatch = cmap(1, "id", v_str("item01"));
  return ctx;
}

// ---- custom features for the feature_hook / feature_init tests -------------

typedef struct { Feature base; bool* called; } HookFeat;
static const char* hf_name(Feature* f) { (void)f; return "hookfeat"; }
static bool hf_active(Feature* f) { (void)f; return true; }
static voxgig_value* hf_addopts(Feature* f) { (void)f; return NULL; }
static void hf_init(Feature* f, Context* c, voxgig_value* o) { (void)f; (void)c; (void)o; }
static void hf_hook(Feature* f, const char* name, Context* c) {
  (void)c;
  if (strcmp(name, "TestHook") == 0) *((HookFeat*)f)->called = true;
}
static const FeatureVT HOOK_VT = { hf_name, hf_active, hf_addopts, hf_init, hf_hook, NULL };
static Feature* hook_feature(bool* called) {
  HookFeat* f = (HookFeat*)calloc(1, sizeof(HookFeat));
  f->base.vt = &HOOK_VT;
  f->called = called;
  return (Feature*)f;
}

typedef struct { Feature base; const char* nm; bool* init_called; } InitFeat;
static const char* if_name(Feature* f) { return ((InitFeat*)f)->nm; }
static bool if_active(Feature* f) { (void)f; return true; }
static voxgig_value* if_addopts(Feature* f) { (void)f; return NULL; }
static void if_init(Feature* f, Context* c, voxgig_value* o) {
  (void)c; (void)o; *((InitFeat*)f)->init_called = true;
}
static void if_hook(Feature* f, const char* n, Context* c) { (void)f; (void)n; (void)c; }
static const FeatureVT INIT_VT = { if_name, if_active, if_addopts, if_init, if_hook, NULL };
static Feature* init_feature(const char* nm, bool* init_called) {
  InitFeat* f = (InitFeat*)calloc(1, sizeof(InitFeat));
  f->base.vt = &INIT_VT;
  f->nm = nm;
  f->init_called = init_called;
  return (Feature*)f;
}

// live system.fetch that records its [url, fetchdef] args.
static voxgig_value* pu_sysfetch(void* ud, voxgig_value* args) {
  voxgig_list_push(voxgig_as_list((voxgig_value*)ud), v_share(args));
  return cmap(2, "status", v_num(200), "statusText", v_str("OK"));
}

// =============================================================================

static void test_primary_utility_exists(void) {
  base_client();
  Context* ctx = test_ctx();
  CHECK_STR_EQ(prepare_method_util(ctx), "GET", "prepare_method GET");
  CHECK(voxgig_is_map(prepare_headers_util(ctx)), "prepare_headers is map");
  CHECK(voxgig_is_map(prepare_query_util(ctx)), "prepare_query is map");
  CHECK(voxgig_is_map(prepare_params_util(ctx)), "prepare_params is map");
  CHECK(voxgig_is_map(make_options_util(ctx)), "make_options is map");
  clean_util(ctx, v_str("x"));
}

static void test_primary_clean_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  voxgig_value* val = cmap(2, "key", v_str("secret123"), "name", v_str("test"));
  CHECK(!v_is_noval(clean_util(ctx, val)), "clean not nil");
}

static void test_primary_prepare_method_basic(void) {
  base_client();
  CHECK_STR_EQ(prepare_method_util(ctx_named("load")), "GET", "method load GET");
  CHECK_STR_EQ(prepare_method_util(ctx_named("list")), "GET", "method list GET");
  CHECK_STR_EQ(prepare_method_util(ctx_named("create")), "POST", "method create POST");
  CHECK_STR_EQ(prepare_method_util(ctx_named("update")), "PUT", "method update PUT");
  CHECK_STR_EQ(prepare_method_util(ctx_named("remove")), "DELETE", "method remove DELETE");
  CHECK_STR_EQ(prepare_method_util(ctx_named("patch")), "PATCH", "method patch PATCH");
}

static void test_primary_prepare_headers_basic(void) {
  base_client();
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.options = cmap(1, "headers", cmap(1, "x-test", v_str("1")));
  Context* ctx = make_context_util(cs, NULL);
  voxgig_value* h = prepare_headers_util(ctx);
  CHECK_STR_EQ(get_str(h, "x-test"), "1", "prepare_headers from options");
}

static void test_primary_prepare_query_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->reqmatch = cmap(1, "filter", v_str("active"));
  ctx->point = cmap(1, "params", v_list());
  voxgig_value* q = prepare_query_util(ctx);
  CHECK_STR_EQ(get_str(q, "filter"), "active", "prepare_query passes non-path reqmatch");
}

static void test_primary_prepare_params_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  voxgig_value* p = prepare_params_util(ctx);
  CHECK_STR_EQ(get_str(p, "id"), "item01", "prepare_params resolves id");
}

static void test_primary_prepare_path_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->point = cmap(1, "parts", clist(3, v_str("api"), v_str("planet"), v_str("{id}")));
  char* path = prepare_path_util(ctx);
  CHECK_STR_EQ(path, "api/planet/{id}", "prepare_path joins parts");
}

static void test_primary_prepare_path_single(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->point = cmap(1, "parts", clist(1, v_str("items")));
  CHECK_STR_EQ(prepare_path_util(ctx), "items", "prepare_path single");
}

static void test_primary_prepare_body_basic(void) {
  base_client();
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "create";
  cs.client = C;
  cs.utility = U;
  cs.reqdata = cmap(1, "name", v_str("x"));
  Context* ctx = make_context_util(cs, sdk_get_root_ctx(C));
  voxgig_value* body = prepare_body_util(ctx);
  CHECK_STR_EQ(get_str(body, "name"), "x", "prepare_body returns reqdata for data op");
}

static void test_primary_make_options_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  voxgig_value* opts = make_options_util(ctx);
  CHECK(voxgig_is_map(opts), "make_options map");
  CHECK(!v_is_noval(getp(opts, "base")), "make_options has base");
}

static void test_primary_make_context_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  CHECK(ctx->id != NULL && ctx->id[0] != '\0', "make_context id set");
  CHECK_STR_EQ(ctx->op->name, "load", "make_context op name");
}

static void test_primary_make_spec_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->options = sdk_options_map(C);
  PNError* err = NULL;
  Spec* spec = make_spec_util(ctx, &err);
  CHECK(err == NULL, "make_spec: no error");
  CHECK_STR_EQ(spec->method, "GET", "make_spec method GET");
}

static void test_primary_make_url_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->spec = spec_new(cmap(9, "base", v_str("http://localhost:8080"), "prefix", v_str("/api"),
                            "path", v_str("items/{id}"), "params", cmap(1, "id", v_str("item01")),
                            "query", v_map(), "headers", v_map(), "method", v_str("GET"),
                            "step", v_str("start"), "suffix", v_str("")));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  char* url = make_url_util(ctx, &err);
  CHECK(err == NULL, "make_url: no error");
  CHECK(strstr(url, "/api/items/item01") != NULL, "make_url substitutes path param");
}

static void test_primary_make_fetch_def_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->spec = spec_new(cmap(9, "base", v_str("http://localhost:8080"), "prefix", v_str("/api"),
                            "path", v_str("items/{id}"), "suffix", v_str(""),
                            "params", cmap(1, "id", v_str("item01")), "query", v_map(),
                            "headers", cmap(1, "content-type", v_str("application/json")),
                            "method", v_str("GET"), "step", v_str("start")));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  voxgig_value* fd = make_fetch_def_util(ctx, &err);
  CHECK_STR_EQ(get_str(fd, "method"), "GET", "make_fetch_def method");
  CHECK(strstr(get_str(fd, "url"), "/api/items/item01") != NULL, "make_fetch_def url");
  CHECK_STR_EQ(get_str(getp(fd, "headers"), "content-type"), "application/json",
               "make_fetch_def headers");
  CHECK(v_is_noval(getp(fd, "body")), "make_fetch_def no body");
}

static void test_primary_make_fetch_def_with_body(void) {
  base_client();
  Context* ctx = full_ctx();
  // 8 pairs, not 9 - cmap is variadic and reads exactly npairs, so an
  // overcount walks off the argument list and the trailing entry (method) is
  // whatever the read finds.
  ctx->spec = spec_new(cmap(8, "base", v_str("http://localhost:8080"), "prefix", v_str(""),
                            "path", v_str("items"), "suffix", v_str(""), "params", v_map(),
                            "query", v_map(), "headers", v_map(), "method", v_str("POST")));
  ctx->spec->body = cmap(1, "name", v_str("test"));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  voxgig_value* fd = make_fetch_def_util(ctx, &err);
  CHECK_STR_EQ(get_str(fd, "method"), "POST", "make_fetch_def POST");
  CHECK(strstr(get_str(fd, "body"), "name") != NULL, "make_fetch_def body has name");
}

static void test_primary_make_point_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  voxgig_value* point = cmap(7, "parts", clist(2, v_str("items"), v_str("{id}")),
                            "args", cmap(1, "params", v_list()), "params", v_list(),
                            "alias", v_map(), "select", v_map(), "active", v_bool(true),
                            "transform", v_map());
  ctx->op = operation_new(cmap(3, "entity", v_str("x"), "name", v_str("load"),
                               "points", clist(1, point)));
  PNError* err = NULL;
  make_point_util(ctx, &err);
  CHECK(err == NULL, "make_point: no error");
  CHECK(!v_is_noval(ctx->point), "make_point sets point");
}

static void test_primary_make_request_basic(void) {
  base_client();
  U->fetcher = fh_recorder(NULL, NULL, NULL);
  Context* ctx = test_ctx();
  ctx->spec = spec_new(cmap(5, "base", v_str("http://h"), "path", v_str("a"),
                            "method", v_str("GET"), "headers", v_map(), "step", v_str("s")));
  PNError* err = NULL;
  Response* resp = make_request_util(ctx, &err);
  CHECK_INT_EQ(resp->status, 200, "make_request status 200");
}

static void test_primary_make_response_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->response = response_new(fh_response(200, cmap(1, "v", v_num(1)), v_undef()));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  make_response_util(ctx, &err);
  CHECK(ctx->result->ok, "make_response ok");
  CHECK_INT_EQ(to_int(getp(ctx->result->body, "v")), 1, "make_response body.v");
}

static void test_primary_make_result_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->spec = spec_new(cmap(1, "step", v_str("start")));
  ctx->result = result_new(cmap(4, "ok", v_bool(true), "status", v_num(200),
                                "statusText", v_str("OK"),
                                "resdata", cmap(2, "id", v_str("item01"), "name", v_str("Test"))));
  PNError* err = NULL;
  SdkResult* result = make_result_util(ctx, &err);
  CHECK_INT_EQ(result->status, 200, "make_result status 200");
}

static void test_primary_make_result_no_spec(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->spec = NULL;
  ctx->result = result_new(cmap(1, "ok", v_bool(true)));
  PNError* err = NULL;
  make_result_util(ctx, &err);
  CHECK(err != NULL, "make_result no spec: error");
}

static void test_primary_make_result_no_result(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->spec = spec_new(cmap(1, "step", v_str("start")));
  ctx->result = NULL;
  PNError* err = NULL;
  make_result_util(ctx, &err);
  CHECK(err != NULL, "make_result no result: error");
}

static void test_primary_operator_basic(void) {
  Operation* op = operation_new(cmap(3, "entity", v_str("widget"), "name", v_str("load"),
                                     "input", v_str("match")));
  CHECK_STR_EQ(op->entity, "widget", "operation entity");
  CHECK_STR_EQ(op->name, "load", "operation name");
  CHECK_STR_EQ(op->input, "match", "operation input");
}

static void test_primary_param_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  voxgig_value* val = param_util(ctx, v_str("id"));
  CHECK(v_str_eq(val, "item01"), "param resolves id");
}

static void test_primary_prepare_auth_basic(void) {
  base_client();
  Context* ctx = full_ctx();
  ctx->spec = spec_new(cmap(2, "headers", v_map(), "step", v_str("s")));
  PNError* err = NULL;
  Spec* spec = prepare_auth_util(ctx, &err);
  CHECK(err == NULL, "prepare_auth basic: no error");
  CHECK(spec != NULL, "prepare_auth basic: spec returned");
}

static void test_primary_transform_request_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->reqdata = cmap(1, "a", v_num(1));
  voxgig_value* out = transform_request_util(ctx);
  CHECK_INT_EQ(to_int(getp(out, "a")), 1, "transform_request passthrough reqdata");
}

static void test_primary_transform_response_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->result = result_new(cmap(1, "ok", v_bool(true)));
  ctx->point = v_map();
  voxgig_value* out = transform_response_util(ctx);
  CHECK(v_is_noval(out), "transform_response undef with no transform");
}

static void test_primary_result_basic_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->response = response_new(fh_response(200, v_undef(), v_undef()));
  ctx->result = result_new(v_map());
  result_basic_util(ctx);
  CHECK_INT_EQ(ctx->result->status, 200, "result_basic status");

  Context* ctx2 = test_ctx();
  ctx2->response = response_new(fh_response(404, v_undef(), v_undef()));
  ctx2->result = result_new(v_map());
  result_basic_util(ctx2);
  CHECK(ctx2->result->err != NULL, "result_basic 4xx err");
}

static void test_primary_result_body_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->response = response_new(fh_response(200, cmap(1, "x", v_num(1)), v_undef()));
  ctx->result = result_new(v_map());
  result_body_util(ctx);
  CHECK_INT_EQ(to_int(getp(ctx->result->body, "x")), 1, "result_body from json");
}

static void test_primary_result_headers_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->response = response_new(fh_response(200, v_undef(), cmap(1, "h", v_str("v"))));
  ctx->result = result_new(v_map());
  result_headers_util(ctx);
  CHECK_STR_EQ(get_str(ctx->result->headers, "h"), "v", "result_headers copied");
}

static void test_primary_done_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->result = result_new(cmap(2, "ok", v_bool(true), "resdata", cmap(1, "id", v_str("i1"))));
  PNError* err = NULL;
  voxgig_value* out = done_util(ctx, &err);
  CHECK_STR_EQ(get_str(out, "id"), "i1", "done resdata");
}

static void test_primary_make_error_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  ctx->result = result_new(cmap(1, "ok", v_bool(false)));
  PNError* out = NULL;
  make_error_util(ctx, context_make_error(ctx, "code_x", "msg"), &out);
  CHECK(out != NULL, "make_error basic: error out");
  CHECK_STR_EQ(out ? out->code : "", "code_x", "make_error basic: code preserved");
}

static void test_primary_make_error_no_throw(void) {
  base_client();
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = C;
  cs.utility = U;
  cs.ctrl = cmap(1, "throw", v_bool(false));
  Context* ctx = make_context_util(cs, sdk_get_root_ctx(C));
  ctx->result = result_new(cmap(2, "ok", v_bool(false), "resdata", cmap(1, "id", v_str("safe01"))));
  PNError* out = NULL;
  voxgig_value* ret = make_error_util(ctx, context_make_error(ctx, "c", "m"), &out);
  CHECK(out == NULL, "make_error no-throw: no error out");
  CHECK_STR_EQ(get_str(ret, "id"), "safe01", "make_error no-throw: resdata");
}

static void test_primary_feature_add_basic(void) {
  base_client();
  Context* ctx = test_ctx();
  size_t start = C->features_len;
  feature_add_util(ctx, feature_base_new());
  CHECK_INT_EQ(C->features_len, (int64_t)(start + 1), "feature_add grows list");
}

static void test_primary_feature_hook_basic(void) {
  base_client();
  bool called = false;
  C->features_len = 0;
  sdk_features_push(C, hook_feature(&called));
  Context* ctx = test_ctx();
  feature_hook_util(ctx, "TestHook");
  CHECK(called, "feature_hook dispatched TestHook");
}

static void test_primary_feature_init_basic(void) {
  base_client();
  bool init_called = false;
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = C;
  cs.utility = U;
  cs.options = cmap(1, "feature", cmap(1, "initfeat", cmap(1, "active", v_bool(true))));
  Context* ctx = make_context_util(cs, sdk_get_root_ctx(C));
  feature_init_util(ctx, init_feature("initfeat", &init_called));
  CHECK(init_called, "feature_init calls init for active feature");
}

static void test_primary_feature_init_inactive(void) {
  base_client();
  bool init_called = false;
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = C;
  cs.utility = U;
  cs.options = cmap(1, "feature", cmap(1, "nofeat", cmap(1, "active", v_bool(false))));
  Context* ctx = make_context_util(cs, sdk_get_root_ctx(C));
  feature_init_util(ctx, init_feature("nofeat", &init_called));
  CHECK(!init_called, "feature_init skips inactive feature");
}

static void test_primary_fetcher_live(void) {
  voxgig_value* calls = v_list();
  UnivecSDK* live = projectname_sdk_new(
      cmap(1, "system", cmap(1, "fetch", vfn(pu_sysfetch, calls))));
  Utility* util = sdk_get_utility(live);
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = live;
  cs.utility = util;
  Context* ctx = make_context_util(cs, NULL);
  voxgig_value* fd = cmap(2, "method", v_str("GET"), "headers", v_map());
  PNError* err = NULL;
  utility_fetch(util, ctx, "http://example.com/test", fd, &err);
  CHECK(err == NULL, "fetcher live: no error");
  CHECK_INT_EQ((int)voxgig_list_len(voxgig_as_list(calls)), 1, "fetcher live: 1 call");
  voxgig_value* args0 = voxgig_getelem(calls, v_int(0), v_undef());
  voxgig_value* url0 = voxgig_getelem(args0, v_int(0), v_undef());
  CHECK(v_str_eq(url0, "http://example.com/test"), "fetcher live: url passed");
}

static void test_primary_fetcher_blocked_test_mode(void) {
  UnivecSDK* blocked = projectname_sdk_new(
      cmap(1, "system", cmap(1, "fetch", vfn(pu_sysfetch, v_list()))));
  free(blocked->mode);
  blocked->mode = strdup("test");
  Utility* util = sdk_get_utility(blocked);
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = blocked;
  cs.utility = util;
  Context* ctx = make_context_util(cs, NULL);
  voxgig_value* fd = cmap(2, "method", v_str("GET"), "headers", v_map());
  PNError* err = NULL;
  utility_fetch(util, ctx, "http://example.com/test", fd, &err);
  CHECK(err != NULL, "fetcher blocked: error");
  bool has_blocked = err && err->msg && (strstr(err->msg, "blocked") != NULL ||
                                         strstr(err->msg, "Blocked") != NULL);
  CHECK(has_blocked, "fetcher blocked: message contains 'blocked'");
}

static void test_primary_new_sdk_smoke(void) {
  UnivecSDK* client = projectname_sdk_new(v_undef());
  CHECK_STR_EQ(client->mode, "live", "new sdk mode live");
}

// =============================================================================

int main(void) {
  RUN(test_primary_utility_exists);
  RUN(test_primary_clean_basic);
  RUN(test_primary_prepare_method_basic);
  RUN(test_primary_prepare_headers_basic);
  RUN(test_primary_prepare_query_basic);
  RUN(test_primary_prepare_params_basic);
  RUN(test_primary_prepare_path_basic);
  RUN(test_primary_prepare_path_single);
  RUN(test_primary_prepare_body_basic);
  RUN(test_primary_make_options_basic);
  RUN(test_primary_make_context_basic);
  RUN(test_primary_make_spec_basic);
  RUN(test_primary_make_url_basic);
  RUN(test_primary_make_fetch_def_basic);
  RUN(test_primary_make_fetch_def_with_body);
  RUN(test_primary_make_point_basic);
  RUN(test_primary_make_request_basic);
  RUN(test_primary_make_response_basic);
  RUN(test_primary_make_result_basic);
  RUN(test_primary_make_result_no_spec);
  RUN(test_primary_make_result_no_result);
  RUN(test_primary_operator_basic);
  RUN(test_primary_param_basic);
  RUN(test_primary_prepare_auth_basic);
  RUN(test_primary_transform_request_basic);
  RUN(test_primary_transform_response_basic);
  RUN(test_primary_result_basic_basic);
  RUN(test_primary_result_body_basic);
  RUN(test_primary_result_headers_basic);
  RUN(test_primary_done_basic);
  RUN(test_primary_make_error_basic);
  RUN(test_primary_make_error_no_throw);
  RUN(test_primary_feature_add_basic);
  RUN(test_primary_feature_hook_basic);
  RUN(test_primary_feature_init_basic);
  RUN(test_primary_feature_init_inactive);
  RUN(test_primary_fetcher_live);
  RUN(test_primary_fetcher_blocked_test_mode);
  RUN(test_primary_new_sdk_smoke);

  printf("primary: %d unit tests run\n", TESTS);
  TEST_SUMMARY("primary");
}
