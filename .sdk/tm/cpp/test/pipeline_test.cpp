// Univec SDK — direct unit tests for the operation-pipeline utilities
// (mirrors java test/PipelineTest.java + tm/go/test/pipeline_test.go). The
// generated entity tests exercise the happy path; these drive the error and
// edge branches (missing spec/response/result, 4xx handling, transport
// failures, feature add semantics, auth header shaping) that a normal
// success-path op never reaches. All utilities are reached through the client
// utility, so this suite is API-agnostic.

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "harness.hpp"

using namespace sdk;
using namespace sdk::fh;

// plClient builds a client + isolated utility for pipeline utility tests.
static std::shared_ptr<UnivecSDK> plClient(const Value& sdkopts) {
  return UnivecSDK::testSDK(Value::undef(), sdkopts);
}

static CtxPtr plCtx(std::shared_ptr<UnivecSDK> client, UtilityPtr utility, const Value& ctrl) {
  CtxSpec cs;
  cs.setOpname("load");
  cs.client = client.get();
  cs.utility = utility;
  if (ctrl.is_map()) cs.ctrlMap = ctrl;
  return utility->makeContext(cs, client->getRootCtx());
}

// PlEntity is a minimal fake entity for the list-wrap test. C++ Value cannot
// hold entity instances, so data() calls are counted via a shared counter.
struct PlEntity : public Entity {
  std::string nm;
  std::shared_ptr<int> made;
  PlEntity(const std::string& n, std::shared_ptr<int> m) : nm(n), made(m) {}
  std::string getName() override { return nm; }
  EntityPtr make() override { return std::make_shared<PlEntity>(nm, made); }
  Value data(const Value& arg = Value::undef()) override {
    if (!arg.is_undef() && !arg.is_null()) (*made)++;
    return Value::undef();
  }
  Value match(const Value& arg = Value::undef()) override { return Value::undef(); }

  // Every operation resolves to the entity; `remove` marks it. The fake has
  // to satisfy the same interface the real entities do.
  void markDeleted() override {}
  bool deleted() override { return false; }
};

static std::string errCodeOf(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const SdkErrorPtr& e) {
    return e->code;
  }
  return "";
}

static bool threw(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const SdkErrorPtr&) {
    return true;
  }
  return false;
}

static Value stepSpecMap() { return vmap({{"step", Value("s")}}); }

// --- makeResponse -----------------------------------------------------------

static void makeResponse_guardsMissingSpecResponseResult() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = nullptr;
  ctx->response = std::make_shared<Response>(vmap());
  ctx->result = std::make_shared<Result>(vmap());
  ASSERT_EQ(errCodeOf([&] { utility->makeResponse(ctx); }), std::string("response_no_spec"),
            "expected response_no_spec");

  ctx = plCtx(client, utility, Value::undef());
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->response = nullptr;
  ctx->result = std::make_shared<Result>(vmap());
  ASSERT_EQ(errCodeOf([&] { utility->makeResponse(ctx); }), std::string("response_no_response"),
            "expected response_no_response");

  ctx = plCtx(client, utility, Value::undef());
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->response = std::make_shared<Response>(vmap());
  ctx->result = nullptr;
  ASSERT_EQ(errCodeOf([&] { utility->makeResponse(ctx); }), std::string("response_no_result"),
            "expected response_no_result");
}

static void makeResponse_4xxSetsResultErrAndCopiesHeaders() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->response = std::make_shared<Response>(fhResponse(404, Value(nullptr), fhMap({{"x-a", Value("1")}})));
  ctx->result = std::make_shared<Result>(vmap());
  utility->makeResponse(ctx);
  ASSERT_NOTNULL(ctx->result->err, "expected result.err set on 4xx");
  ASSERT_EQ(ctx->result->status, 404, "expected status 404");
  ASSERT_EQ_VAL(getp(ctx->result->headers, "x-a"), Value("1"), "expected header x-a");
}

static void makeResponse_2xxParsesBodyAndMarksOk() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->response = std::make_shared<Response>(fhResponse(200, fhMap({{"v", Value(1)}}), Value::undef()));
  ctx->result = std::make_shared<Result>(vmap());
  utility->makeResponse(ctx);
  ASSERT_TRUE(ctx->result->ok, "expected ok result");
  Value body = ctx->result->body;
  ASSERT_TRUE(body.is_map(), "expected parsed body");
  ASSERT_EQ_VAL(getp(body, "v"), Value(1), "expected body.v == 1");
}

static void makeResponse_recordsToCtrlExplain() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, fhMap({{"explain", vmap()}}));
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->response = std::make_shared<Response>(fhResponse(200, fhMap({{"v", Value(2)}}), Value::undef()));
  ctx->result = std::make_shared<Result>(vmap());
  utility->makeResponse(ctx);
  ASSERT_NOVAL(getp(ctx->ctrl->explain, "result"), "expected explain.result recorded");
}

// --- makeResult -------------------------------------------------------------

static void makeResult_guardsMissingSpecResult() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = nullptr;
  ctx->result = std::make_shared<Result>(vmap());
  ASSERT_EQ(errCodeOf([&] { utility->makeResult(ctx); }), std::string("result_no_spec"),
            "expected result_no_spec");

  ctx = plCtx(client, utility, Value::undef());
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->result = nullptr;
  ASSERT_EQ(errCodeOf([&] { utility->makeResult(ctx); }), std::string("result_no_result"),
            "expected result_no_result");
}

static void makeResult_listOpWrapsResdataIntoEntities() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  auto counter = std::make_shared<int>(0);
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->op = std::make_shared<Operation>(vmap({{"entity", Value("x")}, {"name", Value("list")}}));
  auto pl = std::make_shared<PlEntity>("x", counter);
  ctx->entity = pl.get();
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  Value resdata = vlist({fhMap({{"a", Value(1)}}), fhMap({{"a", Value(2)}})});
  ctx->result = std::make_shared<Result>(vmap({{"resdata", resdata}}));

  ResultPtr result = utility->makeResult(ctx);
  ASSERT_TRUE(result->resdata.is_list(), "expected list resdata");
  ASSERT_EQ((int)result->resdata.as_list()->size(), 2, "expected 2 wrapped entities");
  ASSERT_EQ(*counter, 2, "expected 2 data() calls");
}

static void makeResult_emptyListYieldsEmptyResdata() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  auto counter = std::make_shared<int>(0);
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->op = std::make_shared<Operation>(vmap({{"entity", Value("x")}, {"name", Value("list")}}));
  auto pl = std::make_shared<PlEntity>("x", counter);
  ctx->entity = pl.get();
  ctx->spec = std::make_shared<Spec>(stepSpecMap());
  ctx->result = std::make_shared<Result>(vmap({{"resdata", vlist()}}));

  ResultPtr result = utility->makeResult(ctx);
  ASSERT_TRUE(result->resdata.is_list(), "expected list resdata");
  ASSERT_EQ((int)result->resdata.as_list()->size(), 0, "expected empty resdata");
}

// --- makeRequest ------------------------------------------------------------

static SpecPtr reqSpec() {
  return std::make_shared<Spec>(vmap({
      {"base", Value("http://h")},
      {"path", Value("a")},
      {"method", Value("GET")},
      {"headers", vmap()},
      {"step", Value("s")}}));
}

static void makeRequest_guardsMissingSpec() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  utility->fetcher = [](CtxPtr, const std::string&, const Value&) -> Value {
    return fhResponse(200, Value(nullptr), Value::undef());
  };

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = nullptr;
  ASSERT_EQ(errCodeOf([&] { utility->makeRequest(ctx); }), std::string("request_no_spec"),
            "expected request_no_spec");
}

static void makeRequest_transportErrorCarriedOnResponse() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  utility->fetcher = [](CtxPtr ctx, const std::string&, const Value&) -> Value {
    throw ctx->makeError("boom", "boom");
  };

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = reqSpec();
  ResponsePtr resp = utility->makeRequest(ctx);
  ASSERT_NOTNULL(resp->err, "expected transport error carried");
  ASSERT_EQ(fhErrCode(resp->err), std::string("boom"), "expected boom code");
}

static void makeRequest_nilTransportResultBecomesResponseError() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  utility->fetcher = [](CtxPtr, const std::string&, const Value&) -> Value { return Value::undef(); };

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = reqSpec();
  ResponsePtr resp = utility->makeRequest(ctx);
  ASSERT_NOTNULL(resp->err, "expected response error for nil transport result");
}

static void makeRequest_normalTransportResponseWrapped() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  utility->fetcher = [](CtxPtr, const std::string&, const Value&) -> Value {
    return fhResponse(200, fhMap({{"a", Value(1)}}), Value::undef());
  };

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = reqSpec();
  ResponsePtr resp = utility->makeRequest(ctx);
  ASSERT_EQ(resp->status, 200, "expected status 200");
}

static void makeRequest_recordsFetchdefToCtrlExplain() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  utility->fetcher = [](CtxPtr, const std::string&, const Value&) -> Value {
    return fhResponse(200, Value(nullptr), Value::undef());
  };

  CtxPtr ctx = plCtx(client, utility, fhMap({{"explain", vmap()}}));
  ctx->spec = reqSpec();
  utility->makeRequest(ctx);
  ASSERT_NOVAL(getp(ctx->ctrl->explain, "fetchdef"), "expected explain.fetchdef recorded");
}

// --- done / makeError -------------------------------------------------------

static void done_returnsResdataOnSuccess() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->result = std::make_shared<Result>(vmap({{"ok", Value(true)}, {"resdata", fhMap({{"id", Value("i1")}})}}));
  Value out = utility->done(ctx);
  ASSERT_TRUE(out.is_map(), "expected resdata");
  ASSERT_EQ_VAL(getp(out, "id"), Value("i1"), "expected id i1");
}

static void done_errorsWhenNotOk() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->result = std::make_shared<Result>(vmap({{"ok", Value(false)}}));
  ASSERT_TRUE(threw([&] { utility->done(ctx); }), "expected an error when result not ok");
}

static void makeError_returnsResdataWhenThrowFalse() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->ctrl->throwing = Value(false);
  ctx->result = std::make_shared<Result>(vmap({{"ok", Value(false)}, {"resdata", Value("fallback")}}));
  Value out = utility->makeError(ctx, ctx->makeError("test_code", "test message"));
  ASSERT_EQ_VAL(out, Value("fallback"), "expected fallback");
}

static void makeError_recordsToCtrlExplain() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();

  CtxPtr ctx = plCtx(client, utility, fhMap({{"explain", vmap()}}));
  ctx->ctrl->throwing = Value(false);
  ctx->result = std::make_shared<Result>(vmap({{"ok", Value(false)}}));
  utility->makeError(ctx, ctx->makeError("x", "x"));
  ASSERT_NOVAL(getp(ctx->ctrl->explain, "err"), "expected explain.err recorded");
}

// --- featureAdd -------------------------------------------------------------

static std::shared_ptr<BaseFeature> named(const std::string& nm) {
  auto f = std::make_shared<BaseFeature>();
  f->name = nm;
  return f;
}

static std::string names(std::shared_ptr<UnivecSDK> client) {
  std::string out;
  for (size_t i = 0; i < client->features.size(); i++) {
    if (i > 0) out += ",";
    out += client->features[i]->getName();
  }
  return out;
}

static void featureAdd_appendsByDefault() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  int start = (int)client->features.size();
  auto f = std::make_shared<BaseFeature>();
  utility->featureAdd(ctx, f);
  ASSERT_EQ((int)client->features.size(), start + 1, "expected one more feature");
  ASSERT_TRUE(client->features.back().get() == f.get(), "expected the feature appended last");
}

static void featureAdd_orderingBeforeAfterReplace() {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  client->features.clear();

  utility->featureAdd(ctx, named("a"));
  utility->featureAdd(ctx, named("b"));
  ASSERT_EQ(names(client), std::string("a,b"), "setup");

  auto before = named("z1");
  before->addOpts = fhMap({{"__before__", Value("b")}});
  utility->featureAdd(ctx, before);
  ASSERT_EQ(names(client), std::string("a,z1,b"), "__before__");

  auto after = named("z2");
  after->addOpts = fhMap({{"__after__", Value("a")}});
  utility->featureAdd(ctx, after);
  ASSERT_EQ(names(client), std::string("a,z2,z1,b"), "__after__");

  auto repl = named("z3");
  repl->addOpts = fhMap({{"__replace__", Value("z1")}});
  utility->featureAdd(ctx, repl);
  ASSERT_EQ(names(client), std::string("a,z2,z3,b"), "__replace__");

  auto miss = named("z4");
  miss->addOpts = fhMap({{"__before__", Value("missing")}});
  utility->featureAdd(ctx, miss);
  ASSERT_EQ(names(client), std::string("a,z2,z3,b,z4"), "fallback append");
}

// --- prepareAuth ------------------------------------------------------------

static SpecPtr authSpec(const Value& headers) {
  return std::make_shared<Spec>(vmap({
      {"headers", headers.is_map() ? headers : vmap()},
      {"step", Value("s")}}));
}

static void prepareAuth_guardsMissingSpec() {
  auto client = plClient(fhMap({{"apikey", Value("K")}}));
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = nullptr;
  ASSERT_EQ(errCodeOf([&] { utility->prepareAuth(ctx); }), std::string("auth_no_spec"),
            "expected auth_no_spec");
}

static void prepareAuth_apikeyWithPrefixSpaceJoined() {
  auto client = plClient(fhMap({{"apikey", Value("K")}, {"auth", fhMap({{"prefix", Value("Bearer")}})}}));
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = authSpec(Value::undef());
  utility->prepareAuth(ctx);
  ASSERT_EQ_VAL(getp(ctx->spec->headers, "authorization"), Value("Bearer K"), "expected Bearer K");
}

static void prepareAuth_rawApikeyEmptyPrefixAsIs() {
  auto client = plClient(fhMap({{"apikey", Value("K")}, {"auth", fhMap({{"prefix", Value("")}})}}));
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = authSpec(Value::undef());
  utility->prepareAuth(ctx);
  ASSERT_EQ_VAL(getp(ctx->spec->headers, "authorization"), Value("K"), "expected K");
}

static void prepareAuth_emptyApikeyDropsHeader() {
  auto client = plClient(fhMap({{"apikey", Value("")}, {"auth", fhMap({{"prefix", Value("Bearer")}})}}));
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = authSpec(fhMap({{"authorization", Value("stale")}}));
  utility->prepareAuth(ctx);
  ASSERT_FALSE(map_contains(ctx->spec->headers, "authorization"), "expected authorization dropped");
}

static void prepareAuth_missingApikeyDropsHeader() {
  auto client = plClient(fhMap({{"auth", fhMap({{"prefix", Value("Bearer")}})}}));
  Value options = client->optionsMap();
  Value apikey = getp(options, "apikey");
  if (apikey.is_string() && !apikey.as_string().empty()) {
    // SDK options carry a configured apikey; case not reproducible here.
    return;
  }
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = authSpec(fhMap({{"authorization", Value("stale")}}));
  utility->prepareAuth(ctx);
  ASSERT_FALSE(map_contains(ctx->spec->headers, "authorization"), "expected authorization dropped");
}

static void prepareAuth_publicApiNoAuthBlockDropsHeader() {
  auto client = plClient(fhMap({{"apikey", Value("K")}}));
  Value options = client->optionsMap();
  if (!is_nullish(getp(options, "auth"))) {
    // Option validation supplies an auth shape for this SDK, so a truly
    // auth-less client cannot be constructed here.
    return;
  }
  UtilityPtr utility = client->getUtility();
  CtxPtr ctx = plCtx(client, utility, Value::undef());
  ctx->spec = authSpec(fhMap({{"authorization", Value("stale")}}));
  utility->prepareAuth(ctx);
  ASSERT_TRUE(is_nullish(getp(ctx->spec->headers, "authorization")), "expected authorization dropped");
}

// --- feature order (array form + test-first default) ------------------------

static Value featureOrderOpts(const Value& feature) {
  auto client = plClient(Value::undef());
  UtilityPtr utility = client->getUtility();
  CtxSpec cs;
  cs.utility = utility;
  cs.options = fhMap({{"feature", feature}});
  cs.config = fhMap({{"options", vmap()}});
  CtxPtr ctx = utility->makeContext(cs, nullptr);
  return utility->makeOptions(ctx);
}

static std::string orderJoin(const Value& opts) {
  Value order = Struct::getpath(opts, {"__derived__", "featureorder"});
  std::string out;
  if (order.is_list()) {
    bool first = true;
    for (const auto& v : *order.as_list()) {
      if (!first) out += ",";
      if (v.is_string()) out += v.as_string();
      first = false;
    }
  }
  return out;
}

static void featureOrder_mapIsTestFirst() {
  Value opts = featureOrderOpts(fhMap({
      {"metrics", fhMap({{"active", Value(true)}})},
      {"test", fhMap({{"active", Value(true)}})}}));
  ASSERT_EQ(orderJoin(opts), std::string("test,metrics"), "map is test-first");
}

static void featureOrder_arrayIsExplicit() {
  Value opts = featureOrderOpts(vlist({
      fhMap({{"name", Value("metrics")}, {"active", Value(true)}}),
      fhMap({{"name", Value("test")}, {"active", Value(true)}})}));
  ASSERT_EQ(orderJoin(opts), std::string("metrics,test"), "array is explicit");
  // the list is normalized to a map for merge/init, opts preserved.
  ASSERT_TRUE(is_true(Struct::getpath(opts, {"feature", "metrics", "active"})),
              "metrics.active preserved");
  ASSERT_TRUE(is_true(Struct::getpath(opts, {"feature", "test", "active"})),
              "test.active preserved");
}

static void featureOrder_mapNoTestSorted() {
  Value opts = featureOrderOpts(fhMap({
      {"retry", fhMap({{"active", Value(true)}})},
      {"cache", fhMap({{"active", Value(true)}})}}));
  ASSERT_EQ(orderJoin(opts), std::string("cache,retry"), "map no-test sorted");
}

int main() {
  T_RUN(makeResponse_guardsMissingSpecResponseResult);
  T_RUN(makeResponse_4xxSetsResultErrAndCopiesHeaders);
  T_RUN(makeResponse_2xxParsesBodyAndMarksOk);
  T_RUN(makeResponse_recordsToCtrlExplain);
  T_RUN(makeResult_guardsMissingSpecResult);
  T_RUN(makeResult_listOpWrapsResdataIntoEntities);
  T_RUN(makeResult_emptyListYieldsEmptyResdata);
  T_RUN(makeRequest_guardsMissingSpec);
  T_RUN(makeRequest_transportErrorCarriedOnResponse);
  T_RUN(makeRequest_nilTransportResultBecomesResponseError);
  T_RUN(makeRequest_normalTransportResponseWrapped);
  T_RUN(makeRequest_recordsFetchdefToCtrlExplain);
  T_RUN(done_returnsResdataOnSuccess);
  T_RUN(done_errorsWhenNotOk);
  T_RUN(makeError_returnsResdataWhenThrowFalse);
  T_RUN(makeError_recordsToCtrlExplain);
  T_RUN(featureAdd_appendsByDefault);
  T_RUN(featureAdd_orderingBeforeAfterReplace);
  T_RUN(featureOrder_mapIsTestFirst);
  T_RUN(featureOrder_arrayIsExplicit);
  T_RUN(featureOrder_mapNoTestSorted);
  T_RUN(prepareAuth_guardsMissingSpec);
  T_RUN(prepareAuth_apikeyWithPrefixSpaceJoined);
  T_RUN(prepareAuth_rawApikeyEmptyPrefixAsIs);
  T_RUN(prepareAuth_emptyApikeyDropsHeader);
  T_RUN(prepareAuth_missingApikeyDropsHeader);
  T_RUN(prepareAuth_publicApiNoAuthBlockDropsHeader);
  return sdktest::summary("pipeline_test");
}
