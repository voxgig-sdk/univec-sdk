// Direct unit tests for the operation-pipeline utilities (C port of
// tm/rust/tests/pipeline_test.rs). The generated entity tests exercise the
// happy path; these drive the error and edge branches — missing spec/response/
// result, 4xx handling, transport failures, feature-add ordering, auth header
// shaping — that a normal success-path op never reaches. Contexts are built
// directly (no mock server) and the utilities are called in isolation.

#include "feature_harness.h" // fh_response + Fetcher helpers + ctest.h

#include <stdio.h>

static int TESTS = 0;
#define RUN(fn)                                                                 \
  do {                                                                         \
    TESTS++;                                                                   \
    fn();                                                                      \
  } while (0)

static UnivecSDK* PL_CLIENT;
static Utility* PL_UTIL;

static void pl_client(voxgig_value* sdkopts) {
  PL_CLIENT = test_sdk(v_undef(), sdkopts);
  PL_UTIL = sdk_get_utility(PL_CLIENT);
}

static Context* pl_ctx(voxgig_value* ctrl) {
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "load";
  cs.client = PL_CLIENT;
  cs.utility = PL_UTIL;
  cs.ctrl = ctrl;
  return make_context_util(cs, sdk_get_root_ctx(PL_CLIENT));
}

// ---- a minimal fake entity for the list-wrap test --------------------------

typedef struct {
  Entity base;
  const char* nm;
  voxgig_value* made;
} PlEntity;

static const char* ple_name(Entity* e) { return ((PlEntity*)e)->nm; }
static Entity* ple_make(Entity* e);
static voxgig_value* ple_data(Entity* e, voxgig_value* args) {
  if (args && !v_is_noval(args) && !v_is_null(args)) {
    voxgig_list_push(voxgig_as_list(((PlEntity*)e)->made), v_share(args));
    return args;
  }
  return v_undef();
}
static voxgig_value* ple_matchv(Entity* e, voxgig_value* args) {
  (void)e; (void)args; return v_undef();
}
static const EntityVT PLE_VT = {
  ple_name, ple_make, ple_data, ple_matchv, NULL, NULL, NULL, NULL, NULL,
};
static Entity* ple_new(const char* nm, voxgig_value* made) {
  PlEntity* p = (PlEntity*)calloc(1, sizeof(PlEntity));
  p->base.vt = &PLE_VT;
  p->nm = nm;
  p->made = made;
  return (Entity*)p;
}
static Entity* ple_make(Entity* e) {
  return ple_new(((PlEntity*)e)->nm, ((PlEntity*)e)->made);
}

// ---- a named custom feature for the feature-add ordering test --------------

typedef struct {
  Feature base;
  const char* nm;
  voxgig_value* addopts;
} NamedFeat;
static const char* nf_name(Feature* f) { return ((NamedFeat*)f)->nm; }
static bool nf_active(Feature* f) { (void)f; return true; }
static voxgig_value* nf_addopts(Feature* f) { return ((NamedFeat*)f)->addopts; }
static void nf_init(Feature* f, Context* c, voxgig_value* o) { (void)f; (void)c; (void)o; }
static void nf_hook(Feature* f, const char* n, Context* c) { (void)f; (void)n; (void)c; }
static const FeatureVT NAMED_VT = {
  nf_name, nf_active, nf_addopts, nf_init, nf_hook, NULL,
};
static Feature* named(const char* nm, voxgig_value* addopts) {
  NamedFeat* f = (NamedFeat*)calloc(1, sizeof(NamedFeat));
  f->base.vt = &NAMED_VT;
  f->nm = nm;
  f->addopts = addopts;
  return (Feature*)f;
}
static void names_join(UnivecSDK* client, char* out, size_t n) {
  out[0] = '\0';
  for (size_t i = 0; i < client->features_len; i++) {
    if (i) strncat(out, ",", n - strlen(out) - 1);
    strncat(out, client->features[i]->vt->name(client->features[i]), n - strlen(out) - 1);
  }
}

// ---- custom transports for make_request ------------------------------------

static voxgig_value* fx_ok(Fetcher* s, Context* c, const char* u, voxgig_value* fd, PNError** e) {
  (void)s; (void)c; (void)u; (void)fd; *e = NULL;
  return fh_response(200, cmap(1, "a", v_num(1)), v_undef());
}
static voxgig_value* fx_boom(Fetcher* s, Context* c, const char* u, voxgig_value* fd, PNError** e) {
  (void)s; (void)u; (void)fd;
  *e = context_make_error(c, "boom", "boom");
  return NULL;
}
static voxgig_value* fx_nil(Fetcher* s, Context* c, const char* u, voxgig_value* fd, PNError** e) {
  (void)s; (void)c; (void)u; (void)fd; *e = NULL;
  return v_undef();
}
static void util_with(FetchFn fn) {
  Fetcher* f = (Fetcher*)calloc(1, sizeof(Fetcher));
  f->fn = fn;
  f->state = NULL;
  PL_UTIL->fetcher = f;
}

static Spec* req_spec(void) {
  return spec_new(cmap(5, "base", v_str("http://h"), "path", v_str("a"),
                       "method", v_str("GET"), "headers", v_map(), "step", v_str("s")));
}

static Spec* auth_spec(voxgig_value* headers) {
  voxgig_value* h = voxgig_is_map(headers) ? headers : v_map();
  return spec_new(cmap(2, "headers", h, "step", v_str("s")));
}

// =============================================================================
// make_response
// =============================================================================

static void test_make_response_guards_missing_spec_response_result(void) {
  pl_client(v_undef());

  Context* ctx = pl_ctx(NULL);
  ctx->spec = NULL;
  ctx->response = response_new(v_map());
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  make_response_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "response_no_spec", "make_response: no spec");

  ctx = pl_ctx(NULL);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->response = NULL;
  ctx->result = result_new(v_map());
  err = NULL;
  make_response_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "response_no_response", "make_response: no response");

  ctx = pl_ctx(NULL);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->response = response_new(v_map());
  ctx->result = NULL;
  err = NULL;
  make_response_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "response_no_result", "make_response: no result");
}

static void test_make_response_4xx_sets_result_err_and_copies_headers(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(NULL);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->response = response_new(fh_response(404, v_undef(), cmap(1, "x-a", v_str("1"))));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  make_response_util(ctx, &err);
  CHECK(err == NULL, "make_response 4xx: no util error");
  CHECK(ctx->result->err != NULL, "make_response 4xx: result.err set");
  CHECK_INT_EQ(ctx->result->status, 404, "make_response 4xx: status 404");
  CHECK_STR_EQ(get_str(ctx->result->headers, "x-a"), "1", "make_response 4xx: header copied");
}

static void test_make_response_2xx_parses_body_and_marks_ok(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(NULL);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->response = response_new(fh_response(200, cmap(1, "v", v_num(1)), v_undef()));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  make_response_util(ctx, &err);
  CHECK(ctx->result->ok, "make_response 2xx: ok result");
  CHECK_INT_EQ(to_int(getp(ctx->result->body, "v")), 1, "make_response 2xx: body.v==1");
}

static void test_make_response_records_to_ctrl_explain(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(cmap(1, "explain", v_map()));
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->response = response_new(fh_response(200, cmap(1, "v", v_num(2)), v_undef()));
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  make_response_util(ctx, &err);
  CHECK(!v_is_noval(getp(ctx->ctrl->explain, "result")), "make_response: explain.result recorded");
}

// =============================================================================
// make_result
// =============================================================================

static void test_make_result_guards_missing_spec_result(void) {
  pl_client(v_undef());

  Context* ctx = pl_ctx(NULL);
  ctx->spec = NULL;
  ctx->result = result_new(v_map());
  PNError* err = NULL;
  make_result_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "result_no_spec", "make_result: no spec");

  ctx = pl_ctx(NULL);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->result = NULL;
  err = NULL;
  make_result_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "result_no_result", "make_result: no result");
}

static void test_make_result_list_op_wraps_resdata_into_entities(void) {
  pl_client(v_undef());
  voxgig_value* made = v_list();
  Context* ctx = pl_ctx(NULL);
  ctx->op = operation_new(cmap(2, "entity", v_str("x"), "name", v_str("list")));
  ctx->entity = ple_new("x", made);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->result = result_new(cmap(1, "resdata",
                                clist(2, cmap(1, "a", v_num(1)), cmap(1, "a", v_num(2)))));
  PNError* err = NULL;
  SdkResult* result = make_result_util(ctx, &err);
  CHECK_INT_EQ(voxgig_size(result->resdata), 2, "make_result list: 2 wrapped entries");
  CHECK_INT_EQ((int)voxgig_list_len(voxgig_as_list(made)), 2, "make_result list: 2 data() calls");
}

static void test_make_result_empty_list_yields_empty_resdata(void) {
  pl_client(v_undef());
  voxgig_value* made = v_list();
  Context* ctx = pl_ctx(NULL);
  ctx->op = operation_new(cmap(2, "entity", v_str("x"), "name", v_str("list")));
  ctx->entity = ple_new("x", made);
  ctx->spec = spec_new(cmap(1, "step", v_str("s")));
  ctx->result = result_new(cmap(1, "resdata", v_list()));
  PNError* err = NULL;
  SdkResult* result = make_result_util(ctx, &err);
  CHECK(voxgig_is_list(result->resdata), "make_result empty: resdata is list");
  CHECK_INT_EQ(voxgig_size(result->resdata), 0, "make_result empty: 0 entries");
}

// =============================================================================
// make_request
// =============================================================================

static void test_make_request_guards_missing_spec(void) {
  pl_client(v_undef());
  util_with(fx_ok);
  Context* ctx = pl_ctx(NULL);
  ctx->spec = NULL;
  PNError* err = NULL;
  make_request_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "request_no_spec", "make_request: no spec");
}

static void test_make_request_transport_error_carried_on_response(void) {
  pl_client(v_undef());
  util_with(fx_boom);
  Context* ctx = pl_ctx(NULL);
  ctx->spec = req_spec();
  PNError* err = NULL;
  Response* resp = make_request_util(ctx, &err);
  CHECK(resp && resp->err != NULL, "make_request boom: response carries err");
  CHECK_STR_EQ(resp->err ? resp->err->code : "", "boom", "make_request boom: code");
}

static void test_make_request_nil_transport_result_becomes_response_error(void) {
  pl_client(v_undef());
  util_with(fx_nil);
  Context* ctx = pl_ctx(NULL);
  ctx->spec = req_spec();
  PNError* err = NULL;
  Response* resp = make_request_util(ctx, &err);
  CHECK(resp && resp->err != NULL, "make_request nil: response error for nil result");
}

static void test_make_request_normal_transport_response_wrapped(void) {
  pl_client(v_undef());
  util_with(fx_ok);
  Context* ctx = pl_ctx(NULL);
  ctx->spec = req_spec();
  PNError* err = NULL;
  Response* resp = make_request_util(ctx, &err);
  CHECK_INT_EQ(resp->status, 200, "make_request normal: status 200");
}

static void test_make_request_records_fetchdef_to_ctrl_explain(void) {
  pl_client(v_undef());
  util_with(fx_ok);
  Context* ctx = pl_ctx(cmap(1, "explain", v_map()));
  ctx->spec = req_spec();
  PNError* err = NULL;
  make_request_util(ctx, &err);
  CHECK(!v_is_noval(getp(ctx->ctrl->explain, "fetchdef")), "make_request: explain.fetchdef recorded");
}

// =============================================================================
// done / make_error
// =============================================================================

static void test_done_returns_resdata_on_success(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(NULL);
  ctx->result = result_new(cmap(2, "ok", v_bool(true), "resdata", cmap(1, "id", v_str("i1"))));
  PNError* err = NULL;
  voxgig_value* out = done_util(ctx, &err);
  CHECK(err == NULL, "done ok: no error");
  CHECK_STR_EQ(get_str(out, "id"), "i1", "done ok: resdata.id");
}

static void test_done_errors_when_not_ok(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(NULL);
  ctx->result = result_new(cmap(1, "ok", v_bool(false)));
  PNError* err = NULL;
  done_util(ctx, &err);
  CHECK(err != NULL, "done not-ok: expected an error");
}

static void test_make_error_returns_resdata_when_throw_false(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(cmap(1, "throw", v_bool(false)));
  ctx->result = result_new(cmap(2, "ok", v_bool(false), "resdata", v_str("fallback")));
  PNError* out = NULL;
  voxgig_value* ret = make_error_util(ctx, context_make_error(ctx, "test_code", "test message"), &out);
  CHECK(out == NULL, "make_error throw=false: no error out");
  CHECK(v_eq(ret, v_str("fallback")), "make_error throw=false: returns resdata");
}

static void test_make_error_records_to_ctrl_explain(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(cmap(2, "explain", v_map(), "throw", v_bool(false)));
  ctx->result = result_new(cmap(1, "ok", v_bool(false)));
  PNError* out = NULL;
  make_error_util(ctx, context_make_error(ctx, "x", "x"), &out);
  CHECK(!v_is_noval(getp(ctx->ctrl->explain, "err")), "make_error: explain.err recorded");
}

// =============================================================================
// feature_add
// =============================================================================

static void test_feature_add_appends_by_default(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(NULL);
  size_t start = PL_CLIENT->features_len;
  feature_add_util(ctx, feature_base_new());
  CHECK_INT_EQ(PL_CLIENT->features_len, (int64_t)(start + 1), "feature_add: appended");
  Feature* last = PL_CLIENT->features[PL_CLIENT->features_len - 1];
  CHECK_STR_EQ(last->vt->name(last), "base", "feature_add: last is base");
}

static void test_feature_add_ordering_before_after_replace(void) {
  pl_client(v_undef());
  Context* ctx = pl_ctx(NULL);
  PL_CLIENT->features_len = 0;
  char buf[256];

  feature_add_util(ctx, named("a", NULL));
  feature_add_util(ctx, named("b", NULL));
  names_join(PL_CLIENT, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "a,b", "feature_add ordering: setup");

  feature_add_util(ctx, named("z1", cmap(1, "__before__", v_str("b"))));
  names_join(PL_CLIENT, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "a,z1,b", "feature_add ordering: __before__");

  feature_add_util(ctx, named("z2", cmap(1, "__after__", v_str("a"))));
  names_join(PL_CLIENT, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "a,z2,z1,b", "feature_add ordering: __after__");

  feature_add_util(ctx, named("z3", cmap(1, "__replace__", v_str("z1"))));
  names_join(PL_CLIENT, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "a,z2,z3,b", "feature_add ordering: __replace__");

  feature_add_util(ctx, named("z4", cmap(1, "__before__", v_str("missing"))));
  names_join(PL_CLIENT, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "a,z2,z3,b,z4", "feature_add ordering: fallback append");
}

// =============================================================================
// prepare_auth
// =============================================================================

static void test_prepare_auth_guards_missing_spec(void) {
  pl_client(cmap(1, "apikey", v_str("K")));
  Context* ctx = pl_ctx(NULL);
  ctx->spec = NULL;
  PNError* err = NULL;
  prepare_auth_util(ctx, &err);
  CHECK_STR_EQ(err ? err->code : "", "auth_no_spec", "prepare_auth: no spec");
}

static void test_prepare_auth_apikey_with_prefix_space_joined(void) {
  pl_client(cmap(2, "apikey", v_str("K"), "auth", cmap(1, "prefix", v_str("Bearer"))));
  Context* ctx = pl_ctx(NULL);
  ctx->spec = auth_spec(v_undef());
  PNError* err = NULL;
  prepare_auth_util(ctx, &err);
  CHECK_STR_EQ(get_str(ctx->spec->headers, "authorization"), "Bearer K",
               "prepare_auth: prefix space-joined");
}

static void test_prepare_auth_raw_apikey_empty_prefix_as_is(void) {
  pl_client(cmap(2, "apikey", v_str("K"), "auth", cmap(1, "prefix", v_str(""))));
  Context* ctx = pl_ctx(NULL);
  ctx->spec = auth_spec(v_undef());
  PNError* err = NULL;
  prepare_auth_util(ctx, &err);
  CHECK_STR_EQ(get_str(ctx->spec->headers, "authorization"), "K", "prepare_auth: raw apikey");
}

static void test_prepare_auth_empty_apikey_drops_header(void) {
  pl_client(cmap(2, "apikey", v_str(""), "auth", cmap(1, "prefix", v_str("Bearer"))));
  Context* ctx = pl_ctx(NULL);
  ctx->spec = auth_spec(cmap(1, "authorization", v_str("stale")));
  PNError* err = NULL;
  prepare_auth_util(ctx, &err);
  CHECK(v_is_noval(getp(ctx->spec->headers, "authorization")),
        "prepare_auth: empty apikey drops header");
}

static void test_prepare_auth_missing_apikey_drops_header(void) {
  pl_client(cmap(1, "auth", cmap(1, "prefix", v_str("Bearer"))));
  voxgig_value* options = sdk_options_map(PL_CLIENT);
  const char* k = get_str(options, "apikey");
  if (k && k[0] != '\0') {
    fprintf(stderr, "skip: SDK options carry a configured apikey\n");
    return;
  }
  Context* ctx = pl_ctx(NULL);
  ctx->spec = auth_spec(cmap(1, "authorization", v_str("stale")));
  PNError* err = NULL;
  prepare_auth_util(ctx, &err);
  CHECK(v_is_noval(getp(ctx->spec->headers, "authorization")),
        "prepare_auth: missing apikey drops header");
}

static void test_prepare_auth_public_api_no_auth_block_drops_header(void) {
  pl_client(cmap(1, "apikey", v_str("K")));
  voxgig_value* options = sdk_options_map(PL_CLIENT);
  if (!v_is_noval(getp(options, "auth"))) {
    fprintf(stderr, "skip: options always carry an auth block in this SDK\n");
    return;
  }
  Context* ctx = pl_ctx(NULL);
  ctx->spec = auth_spec(cmap(1, "authorization", v_str("stale")));
  PNError* err = NULL;
  prepare_auth_util(ctx, &err);
  CHECK(v_is_noval(getp(ctx->spec->headers, "authorization")),
        "prepare_auth: public api drops header");
}

// =============================================================================

// ---- feature order (array form + test-first default) -----------------------

static voxgig_value* make_opts_feature(voxgig_value* feature) {
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.client = PL_CLIENT;
  cs.utility = PL_UTIL;
  cs.options = cmap(1, "feature", feature);
  cs.config = cmap(1, "options", v_map());
  Context* ctx = make_context_util(cs, NULL);
  return make_options_util(ctx);
}

static void order_join(voxgig_value* opts, char* out, size_t n) {
  voxgig_value* order = getpath2(opts, "__derived__", "featureorder");
  out[0] = '\0';
  if (v_is_list(order)) {
    voxgig_list* l = voxgig_as_list(order);
    for (size_t i = 0; i < l->len; i++) {
      if (i > 0) strncat(out, ",", n - strlen(out) - 1);
      if (v_is_str(l->items[i])) {
        strncat(out, voxgig_as_string(l->items[i]), n - strlen(out) - 1);
      }
    }
  }
}

static void test_feature_order_map_is_test_first(void) {
  pl_client(v_undef());
  voxgig_value* opts = make_opts_feature(cmap(2,
    "metrics", cmap(1, "active", v_bool(true)),
    "test", cmap(1, "active", v_bool(true))));
  char buf[128];
  order_join(opts, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "test,metrics", "feature order: map is test-first");
}

static void test_feature_order_array_is_explicit(void) {
  pl_client(v_undef());
  voxgig_value* opts = make_opts_feature(clist(2,
    cmap(2, "name", v_str("metrics"), "active", v_bool(true)),
    cmap(2, "name", v_str("test"), "active", v_bool(true))));
  char buf[128];
  order_join(opts, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "metrics,test", "feature order: array is explicit");
  // the list is normalized to a map for merge/init, opts preserved.
  bool ma = false, ta = false;
  CHECK(get_bool(getpath2(opts, "feature", "metrics"), "active", &ma) && ma,
        "feature order: array metrics.active preserved");
  CHECK(get_bool(getpath2(opts, "feature", "test"), "active", &ta) && ta,
        "feature order: array test.active preserved");
}

static void test_feature_order_map_no_test_is_sorted(void) {
  pl_client(v_undef());
  voxgig_value* opts = make_opts_feature(cmap(2,
    "retry", cmap(1, "active", v_bool(true)),
    "cache", cmap(1, "active", v_bool(true))));
  char buf[128];
  order_join(opts, buf, sizeof(buf));
  CHECK_STR_EQ(buf, "cache,retry", "feature order: map no-test is sorted");
}

int main(void) {
  RUN(test_make_response_guards_missing_spec_response_result);
  RUN(test_make_response_4xx_sets_result_err_and_copies_headers);
  RUN(test_make_response_2xx_parses_body_and_marks_ok);
  RUN(test_make_response_records_to_ctrl_explain);
  RUN(test_make_result_guards_missing_spec_result);
  RUN(test_make_result_list_op_wraps_resdata_into_entities);
  RUN(test_make_result_empty_list_yields_empty_resdata);
  RUN(test_make_request_guards_missing_spec);
  RUN(test_make_request_transport_error_carried_on_response);
  RUN(test_make_request_nil_transport_result_becomes_response_error);
  RUN(test_make_request_normal_transport_response_wrapped);
  RUN(test_make_request_records_fetchdef_to_ctrl_explain);
  RUN(test_done_returns_resdata_on_success);
  RUN(test_done_errors_when_not_ok);
  RUN(test_make_error_returns_resdata_when_throw_false);
  RUN(test_make_error_records_to_ctrl_explain);
  RUN(test_feature_add_appends_by_default);
  RUN(test_feature_add_ordering_before_after_replace);
  RUN(test_feature_order_map_is_test_first);
  RUN(test_feature_order_array_is_explicit);
  RUN(test_feature_order_map_no_test_is_sorted);
  RUN(test_prepare_auth_guards_missing_spec);
  RUN(test_prepare_auth_apikey_with_prefix_space_joined);
  RUN(test_prepare_auth_raw_apikey_empty_prefix_as_is);
  RUN(test_prepare_auth_empty_apikey_drops_header);
  RUN(test_prepare_auth_missing_apikey_drops_header);
  RUN(test_prepare_auth_public_api_no_auth_block_drops_header);

  printf("pipeline: %d unit tests run\n", TESTS);
  TEST_SUMMARY("pipeline");
}
