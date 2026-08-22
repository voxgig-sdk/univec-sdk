// Univec SDK — drives the primary utility functions against the shared
// test.json spec (../.sdk/test/test.json, section "primary"). Mirrors
// java test/PrimaryUtilityTest.java + tm/go/test/primary_utility_test.go.

#include <memory>
#include <string>
#include <vector>

#include "runner_support.hpp"
#include "harness.hpp"

using namespace sdk;
using namespace sdk::fh;

static Value primary() {
  return rs::get_spec(rs::load_test_spec(), {"primary"});
}

static std::shared_ptr<UnivecSDK> client() { return UnivecSDK::testSDK(); }

// Helper: create basic test context.
static CtxPtr makeTestCtx(std::shared_ptr<UnivecSDK> client_, UtilityPtr utility) {
  CtxSpec cs;
  cs.setOpname("load");
  cs.client = client_.get();
  cs.utility = utility;
  return utility->makeContext(cs, client_->getRootCtx());
}

// Helper: create full test context with point and match.
static CtxPtr makeTestFullCtx(std::shared_ptr<UnivecSDK> client_, UtilityPtr utility) {
  CtxPtr ctx = makeTestCtx(client_, utility);
  ctx->point = fhMap({
      {"parts", vlist({Value("items"), Value("{id}")})},
      {"args", fhMap({{"params", vlist({fhMap({{"name", Value("id")}, {"reqd", Value(true)}})})}})},
      {"params", vlist({Value("id")})},
      {"alias", vmap()},
      {"select", vmap()},
      {"active", Value(true)},
      {"transform", vmap()}});
  ctx->match = fhMap({{"id", Value("item01")}});
  ctx->reqmatch = fhMap({{"id", Value("item01")}});
  return ctx;
}

// errFromMap creates an error from a JSON map {"message": "...", "code": "..."}.
static SdkErrorPtr errFromMap(const Value& m) {
  if (!m.is_map()) return nullptr;
  std::string msg = as_str(getp(m, "message"));
  if (msg.empty()) return nullptr;
  std::string code = as_str(getp(m, "code"));
  return std::make_shared<SdkError>(code, msg, nullptr);
}

static Value pointsToValue(const std::vector<Value>& pts) {
  Value out = vlist();
  for (const auto& p : pts) out.as_list()->push_back(p);
  return out;
}

// --- exists -----------------------------------------------------------------

static void exists() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  ASSERT_TRUE((bool)utility->clean, "clean");
  ASSERT_TRUE((bool)utility->done, "done");
  ASSERT_TRUE((bool)utility->makeError, "makeError");
  ASSERT_TRUE((bool)utility->featureAdd, "featureAdd");
  ASSERT_TRUE((bool)utility->featureHook, "featureHook");
  ASSERT_TRUE((bool)utility->featureInit, "featureInit");
  ASSERT_TRUE((bool)utility->fetcher, "fetcher");
  ASSERT_TRUE((bool)utility->makeFetchDef, "makeFetchDef");
  ASSERT_TRUE((bool)utility->makeContext, "makeContext");
  ASSERT_TRUE((bool)utility->makeOptions, "makeOptions");
  ASSERT_TRUE((bool)utility->makeRequest, "makeRequest");
  ASSERT_TRUE((bool)utility->makeResponse, "makeResponse");
  ASSERT_TRUE((bool)utility->makeResult, "makeResult");
  ASSERT_TRUE((bool)utility->makePoint, "makePoint");
  ASSERT_TRUE((bool)utility->makeSpec, "makeSpec");
  ASSERT_TRUE((bool)utility->makeUrl, "makeUrl");
  ASSERT_TRUE((bool)utility->param, "param");
  ASSERT_TRUE((bool)utility->prepareAuth, "prepareAuth");
  ASSERT_TRUE((bool)utility->prepareBody, "prepareBody");
  ASSERT_TRUE((bool)utility->prepareHeaders, "prepareHeaders");
  ASSERT_TRUE((bool)utility->prepareMethod, "prepareMethod");
  ASSERT_TRUE((bool)utility->prepareParams, "prepareParams");
  ASSERT_TRUE((bool)utility->preparePath, "preparePath");
  ASSERT_TRUE((bool)utility->prepareQuery, "prepareQuery");
  ASSERT_TRUE((bool)utility->resultBasic, "resultBasic");
  ASSERT_TRUE((bool)utility->resultBody, "resultBody");
  ASSERT_TRUE((bool)utility->resultHeaders, "resultHeaders");
  ASSERT_TRUE((bool)utility->transformRequest, "transformRequest");
  ASSERT_TRUE((bool)utility->transformResponse, "transformResponse");
}

// --- clean ------------------------------------------------------------------

static void cleanBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestCtx(c, utility);
  Value cleaned = utility->clean(ctx, fhMap({{"key", Value("secret123")}, {"name", Value("test")}}));
  ASSERT_TRUE(cleaned.is_map(), "cleaned should not be null");
}

// --- done -------------------------------------------------------------------

static void doneBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("done-basic", rs::get_spec(primary(), {"done", "basic"}), [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    rs::fixctx(ctx, c);
    return utility->done(ctx);
  });
}

// --- makeError --------------------------------------------------------------

static void makeErrorBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("makeError-basic", rs::get_spec(primary(), {"makeError", "basic"}), [&](const Value& entry) -> Value {
    Value args = getp(entry, "args");
    if (!args.is_list()) args = vlist();
    if (args.as_list()->empty()) args.as_list()->push_back(vmap());

    Value ctxmap = Helpers::toMapAny(vs::getelem(args, Value(int64_t(0))));
    if (!ctxmap.is_map()) ctxmap = vmap();
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    rs::fixctx(ctx, c);

    SdkErrorPtr err;
    if (args.as_list()->size() > 1) {
      err = errFromMap(Helpers::toMapAny(vs::getelem(args, Value(int64_t(1)))));
    }
    return utility->makeError(ctx, err);
  });
}

static void makeErrorNoThrow() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestFullCtx(c, utility);
  ctx->ctrl->throwing = Value(false);
  ctx->result = std::make_shared<Result>(vmap({{"ok", Value(false)}, {"resdata", fhMap({{"id", Value("safe01")}})}}));

  Value out = utility->makeError(ctx, ctx->makeError("test_code", "test message"));
  Value outMap = Helpers::toMapAny(out);
  ASSERT_TRUE(outMap.is_map(), "expected map result");
  ASSERT_EQ_VAL(getp(outMap, "id"), Value("safe01"), "expected id safe01");
}

// --- feature add / hook / init ----------------------------------------------

static void featureAddBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestCtx(c, utility);
  int startLen = (int)c->features.size();
  utility->featureAdd(ctx, std::make_shared<BaseFeature>());
  ASSERT_EQ((int)c->features.size(), startLen + 1, "expected one more feature");
}

struct TestHookFeature : public BaseFeature {
  bool* flag;
  explicit TestHookFeature(bool* f) : flag(f) {}
  void postConstruct(CtxPtr ctx) override {
    if (flag) *flag = true;
  }
};

static void featureHookBasic() {
  auto hookClient = client();
  UtilityPtr hookUtility = hookClient->getUtility();
  CtxPtr ctx = makeTestCtx(hookClient, hookUtility);

  bool called = false;
  auto hookFeature = std::make_shared<TestHookFeature>(&called);
  hookClient->features.clear();
  hookClient->features.push_back(hookFeature);

  // C++ features have a fixed hook-dispatch table (no reflection): use the
  // real PostConstruct pipeline hook to verify featureHook dispatches.
  hookUtility->featureHook(ctx, "PostConstruct");
  ASSERT_TRUE(called, "expected hook to be called");
}

struct TestInitFeature : public BaseFeature {
  bool* flag;
  TestInitFeature(const std::string& nm, bool act, bool* f) : flag(f) {
    name = nm;
    active = act;
  }
  void init(CtxPtr ctx, const Value& options) override {
    if (flag) *flag = true;
  }
};

static void featureInitBasic() {
  auto initClient = client();
  UtilityPtr initUtility = initClient->getUtility();
  CtxPtr ctx = makeTestCtx(initClient, initUtility);
  map_put(ctx->options, "feature", fhMap({{"initfeat", fhMap({{"active", Value(true)}})}}));

  bool initCalled = false;
  auto feature = std::make_shared<TestInitFeature>("initfeat", true, &initCalled);
  initUtility->featureInit(ctx, feature);
  ASSERT_TRUE(initCalled, "expected init to be called");
}

static void featureInitInactive() {
  auto initClient = client();
  UtilityPtr initUtility = initClient->getUtility();
  CtxPtr ctx = makeTestCtx(initClient, initUtility);
  map_put(ctx->options, "feature", fhMap({{"nofeat", fhMap({{"active", Value(false)}})}}));

  bool initCalled = false;
  auto feature = std::make_shared<TestInitFeature>("nofeat", false, &initCalled);
  initUtility->featureInit(ctx, feature);
  ASSERT_FALSE(initCalled, "expected init NOT to be called for inactive feature");
}

// --- fetcher ----------------------------------------------------------------

static void fetcherLive() {
  auto calls = std::make_shared<std::vector<Value>>();
  vs::Injector fetchFn = [calls](vs::Injection&, const Value& args, const std::string&,
                                 const Value&) -> Value {
    Value url = vs::getelem(args, Value(int64_t(0)));
    Value fetchdef = vs::getelem(args, Value(int64_t(1)));
    calls->push_back(vmap({{"url", url}, {"init", fetchdef}}));
    return vmap({{"status", Value(200)}, {"statusText", Value("OK")}});
  };
  Value opts = fhMap({{"system", fhMap({{"fetch", Value(fetchFn)}})}});
  auto liveClient = std::make_shared<UnivecSDK>(opts);
  UtilityPtr liveUtility = liveClient->getUtility();

  CtxSpec cs;
  cs.setOpname("load");
  cs.client = liveClient.get();
  cs.utility = liveUtility;
  CtxPtr ctx = liveUtility->makeContext(cs, nullptr);

  Value fetchdef = fhMap({{"method", Value("GET")}, {"headers", vmap()}});
  liveUtility->fetcher(ctx, "http://example.com/test", fetchdef);
  ASSERT_EQ((int)calls->size(), 1, "expected 1 call");
  ASSERT_EQ_VAL(getp((*calls)[0], "url"), Value("http://example.com/test"), "expected url");
}

static void fetcherBlockedTestMode() {
  vs::Injector fetchFn = [](vs::Injection&, const Value&, const std::string&, const Value&) -> Value {
    return vmap();
  };
  Value opts = fhMap({{"system", fhMap({{"fetch", Value(fetchFn)}})}});
  auto blockedClient = std::make_shared<UnivecSDK>(opts);
  blockedClient->mode = "test";

  UtilityPtr blockedUtility = blockedClient->getUtility();
  CtxSpec cs;
  cs.setOpname("load");
  cs.client = blockedClient.get();
  cs.utility = blockedUtility;
  CtxPtr ctx = blockedUtility->makeContext(cs, nullptr);

  Value fetchdef = fhMap({{"method", Value("GET")}, {"headers", vmap()}});
  bool threw = false;
  std::string msg;
  try {
    blockedUtility->fetcher(ctx, "http://example.com/test", fetchdef);
  } catch (const SdkErrorPtr& e) {
    threw = true;
    msg = e->getMessage();
  }
  ASSERT_TRUE(threw, "expected error for test mode fetch");
  ASSERT_TRUE(msg.find("blocked") != std::string::npos, "expected error containing 'blocked'");
}

// --- makeContext ------------------------------------------------------------

static void makeContextBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("makeContext-basic", rs::get_spec(primary(), {"makeContext", "basic"}),
             [&](const Value& entry) -> Value {
    Value in = Helpers::toMapAny(getp(entry, "in"));
    if (!in.is_map()) return Value::undef();
    CtxPtr ctx = rs::make_ctx_from_map(in, c, utility);
    Value out = vmap();
    map_put(out, "id", Value(ctx->id));
    if (ctx->op) {
      map_put(out, "op", fhMap({{"name", Value(ctx->op->name)}, {"input", Value(ctx->op->input)}}));
    }
    return out;
  });
}

// --- makeFetchDef -----------------------------------------------------------

static void makeFetchDefBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestFullCtx(c, utility);
  ctx->spec = std::make_shared<Spec>(fhMap({
      {"base", Value("http://localhost:8080")},
      {"prefix", Value("/api")},
      {"path", Value("items/{id}")},
      {"suffix", Value("")},
      {"params", fhMap({{"id", Value("item01")}})},
      {"query", vmap()},
      {"headers", fhMap({{"content-type", Value("application/json")}})},
      {"method", Value("GET")},
      {"step", Value("start")}}));
  ctx->result = std::make_shared<Result>(vmap());

  Value fetchdef = utility->makeFetchDef(ctx);
  ASSERT_EQ_VAL(getp(fetchdef, "method"), Value("GET"), "expected method GET");
  std::string url = as_str(getp(fetchdef, "url"));
  ASSERT_TRUE(url.find("/api/items/item01") != std::string::npos,
              "expected url to contain /api/items/item01");
  ASSERT_EQ_VAL(getp(Helpers::toMapAny(getp(fetchdef, "headers")), "content-type"),
                Value("application/json"), "expected content-type header");
  ASSERT_TRUE(is_nullish(getp(fetchdef, "body")), "expected null body");
}

static void makeFetchDefWithBody() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestFullCtx(c, utility);
  ctx->spec = std::make_shared<Spec>(fhMap({
      {"base", Value("http://localhost:8080")},
      {"prefix", Value("")},
      {"path", Value("items")},
      {"suffix", Value("")},
      {"params", vmap()},
      {"query", vmap()},
      {"headers", vmap()},
      {"method", Value("POST")},
      {"step", Value("start")},
      {"body", fhMap({{"name", Value("test")}})}}));
  ctx->result = std::make_shared<Result>(vmap());

  Value fetchdef = utility->makeFetchDef(ctx);
  ASSERT_EQ_VAL(getp(fetchdef, "method"), Value("POST"), "expected method POST");
  Value body = getp(fetchdef, "body");
  ASSERT_TRUE(body.is_string(), "expected body string");
  ASSERT_TRUE(as_str(body).find("\"name\"") != std::string::npos, "expected body to contain name");
}

// --- makeOptions ------------------------------------------------------------

static void makeOptionsBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("makeOptions-basic", rs::get_spec(primary(), {"makeOptions", "basic"}),
             [&](const Value& entry) -> Value {
    Value in = Helpers::toMapAny(getp(entry, "in"));
    CtxSpec cs;
    if (in.is_map()) {
      Value opt = Helpers::toMapAny(getp(in, "options"));
      if (opt.is_map()) cs.options = opt;
      Value cfg = Helpers::toMapAny(getp(in, "config"));
      if (cfg.is_map()) cs.config = cfg;
    }
    CtxPtr ctx = utility->makeContext(cs, nullptr);
    ctx->client = c.get();
    ctx->utility = utility;
    return utility->makeOptions(ctx);
  });
}

// --- makeRequest ------------------------------------------------------------

static void makeRequestBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("makeRequest-basic", rs::get_spec(primary(), {"makeRequest", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    ctx->options = c->optionsMap();

    utility->makeRequest(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map()) {
      if (ctx->response) map_put(entryCtx, "response", Value("exists"));
      if (ctx->result) map_put(entryCtx, "result", Value("exists"));
    }
    return Value::undef();
  });
}

// --- makeResponse -----------------------------------------------------------

static void makeResponseBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("makeResponse-basic", rs::get_spec(primary(), {"makeResponse", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    rs::fixctx(ctx, c);

    utility->makeResponse(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->result) {
      map_put(entryCtx, "result", fhMap({
          {"ok", Value(ctx->result->ok)},
          {"status", Value(ctx->result->status)},
          {"statusText", Value(ctx->result->statusText)},
          {"headers", ctx->result->headers},
          {"body", ctx->result->body}}));
    }
    return Value::undef();
  });
}

// --- makeResult -------------------------------------------------------------

static void makeResultBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestFullCtx(c, utility);
  ctx->spec = std::make_shared<Spec>(fhMap({
      {"base", Value("http://localhost:8080")},
      {"prefix", Value("/api")},
      {"path", Value("items/{id}")},
      {"suffix", Value("")},
      {"params", fhMap({{"id", Value("item01")}})},
      {"query", vmap()},
      {"headers", vmap()},
      {"method", Value("GET")},
      {"step", Value("start")}}));
  ctx->result = std::make_shared<Result>(fhMap({
      {"ok", Value(true)},
      {"status", Value(200)},
      {"statusText", Value("OK")},
      {"headers", vmap()},
      {"resdata", fhMap({{"id", Value("item01")}, {"name", Value("Test")}})}}));

  ResultPtr result = utility->makeResult(ctx);
  ASSERT_EQ(result->status, 200, "expected status 200");
}

static void makeResultNoSpec() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestFullCtx(c, utility);
  ctx->spec = nullptr;
  ctx->result = std::make_shared<Result>(fhMap({
      {"ok", Value(true)}, {"status", Value(200)}, {"statusText", Value("OK")}, {"headers", vmap()}}));

  bool threw = false;
  try {
    utility->makeResult(ctx);
  } catch (const SdkErrorPtr&) {
    threw = true;
  }
  ASSERT_TRUE(threw, "expected error for null spec");
}

static void makeResultNoResult() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestFullCtx(c, utility);
  ctx->spec = std::make_shared<Spec>(fhMap({{"step", Value("start")}}));
  ctx->result = nullptr;

  bool threw = false;
  try {
    utility->makeResult(ctx);
  } catch (const SdkErrorPtr&) {
    threw = true;
  }
  ASSERT_TRUE(threw, "expected error for null result");
}

// --- makeSpec ---------------------------------------------------------------

static void makeSpecBasic() {
  Value setupOpts = rs::get_spec(primary(), {"makeSpec", "DEF", "setup", "a"});
  auto specClient = UnivecSDK::testSDK(Value::undef(), setupOpts);
  UtilityPtr specUtility = specClient->getUtility();

  rs::runset("makeSpec-basic", rs::get_spec(primary(), {"makeSpec", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, specClient, specUtility);
    ctx->options = specClient->optionsMap();

    specUtility->makeSpec(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->spec) {
      map_put(entryCtx, "spec", fhMap({
          {"base", Value(ctx->spec->base)},
          {"prefix", Value(ctx->spec->prefix)},
          {"suffix", Value(ctx->spec->suffix)},
          {"method", Value(ctx->spec->method)},
          {"params", ctx->spec->params},
          {"query", ctx->spec->query},
          {"headers", ctx->spec->headers},
          {"step", Value(ctx->spec->step)}}));
    }
    return Value::undef();
  });
}

// --- makePoint --------------------------------------------------------------

static void makePointBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  CtxPtr ctx = makeTestCtx(c, utility);
  Value point = fhMap({
      {"parts", vlist({Value("items"), Value("{id}")})},
      {"args", fhMap({{"params", vlist()}})},
      {"params", vlist()},
      {"alias", vmap()},
      {"select", vmap()},
      {"active", Value(true)},
      {"transform", vmap()}});
  ctx->op->points = std::vector<Value>{point};

  utility->makePoint(ctx);
  ASSERT_TRUE(ctx->point.is_map(), "expected point to be set");
}

// --- makeUrl ----------------------------------------------------------------

static void makeUrlBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("makeUrl-basic", rs::get_spec(primary(), {"makeUrl", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    if (!ctx->result) ctx->result = std::make_shared<Result>(vmap());
    return Value(utility->makeUrl(ctx));
  });
}

// --- operator ---------------------------------------------------------------

static void operatorBasic() {
  rs::runset("operator-basic", rs::get_spec(primary(), {"operator", "basic"}),
             [&](const Value& entry) -> Value {
    Value in = Helpers::toMapAny(getp(entry, "in"));
    Operation op(in.is_map() ? in : vmap());
    return fhMap({
        {"entity", Value(op.entity)},
        {"name", Value(op.name)},
        {"input", Value(op.input)},
        {"points", pointsToValue(op.points)}});
  });
}

// --- param ------------------------------------------------------------------

static void paramBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("param-basic", rs::get_spec(primary(), {"param", "basic"}),
             [&](const Value& entry) -> Value {
    Value args = getp(entry, "args");
    if (!args.is_list() || args.as_list()->size() < 2) return Value::undef();

    Value ctxmap = Helpers::toMapAny(vs::getelem(args, Value(int64_t(0))));
    if (!ctxmap.is_map()) ctxmap = vmap();
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    Value paramdef = vs::getelem(args, Value(int64_t(1)));

    Value result = utility->param(ctx, paramdef);

    // Copy spec alias back to entry ctx for matching.
    Value matchSpec = Helpers::toMapAny(getp(entry, "match"));
    if (matchSpec.is_map()) {
      Value ctxMatch = Helpers::toMapAny(getp(matchSpec, "ctx"));
      if (ctxMatch.is_map()) {
        Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
        if (!entryCtx.is_map()) {
          entryCtx = vmap();
          map_put(entry, "ctx", entryCtx);
        }
        Value specMatch = Helpers::toMapAny(getp(ctxMatch, "spec"));
        if (specMatch.is_map() && ctx->spec && getp(specMatch, "alias").is_map()) {
          map_put(entryCtx, "spec", fhMap({{"alias", ctx->spec->alias}}));
        }
      }
    }
    return result;
  });
}

// --- prepareAuth ------------------------------------------------------------

static void prepareAuthBasic() {
  Value setupOpts = rs::get_spec(primary(), {"prepareAuth", "DEF", "setup", "a"});
  auto authClient = UnivecSDK::testSDK(Value::undef(), setupOpts);
  UtilityPtr authUtility = authClient->getUtility();

  rs::runset("prepareAuth-basic", rs::get_spec(primary(), {"prepareAuth", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, authClient, authUtility);
    rs::fixctx(ctx, authClient);

    authUtility->prepareAuth(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->spec) {
      map_put(entryCtx, "spec", fhMap({{"headers", ctx->spec->headers}}));
    }
    return Value::undef();
  });
}

// --- prepareBody / prepareHeaders / prepareMethod / prepareParams -----------

static void prepareBodyBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("prepareBody-basic", rs::get_spec(primary(), {"prepareBody", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    rs::fixctx(ctx, c);
    return utility->prepareBody(ctx);
  });
}

static void prepareHeadersBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("prepareHeaders-basic", rs::get_spec(primary(), {"prepareHeaders", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    return utility->prepareHeaders(ctx);
  });
}

static void prepareMethodBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("prepareMethod-basic", rs::get_spec(primary(), {"prepareMethod", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    return Value(utility->prepareMethod(ctx));
  });
}

static void prepareParamsBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("prepareParams-basic", rs::get_spec(primary(), {"prepareParams", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    return utility->prepareParams(ctx);
  });
}

// --- preparePath ------------------------------------------------------------

static void preparePathBasic() {
  // Was hand-written cases that had drifted out of the shared corpus (the
  // preparePath fixture shipped as an empty `set: []`).
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("preparePath-basic", rs::get_spec(primary(), {"preparePath", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    return Value(utility->preparePath(ctx));
  });
}

// --- prepareQuery -----------------------------------------------------------

static void prepareQueryBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("prepareQuery-basic", rs::get_spec(primary(), {"prepareQuery", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    return utility->prepareQuery(ctx);
  });
}

// --- resultBasic / resultBody / resultHeaders -------------------------------

static void resultBasicBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("resultBasic-basic", rs::get_spec(primary(), {"resultBasic", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);
    rs::fixctx(ctx, c);

    ResultPtr result = utility->resultBasic(ctx);

    Value out = fhMap({{"status", Value(result->status)}, {"statusText", Value(result->statusText)}});
    if (result->err) {
      map_put(out, "err", fhMap({{"message", Value(result->err->getMessage())}}));
    }
    return out;
  });
}

static void resultBodyBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("resultBody-basic", rs::get_spec(primary(), {"resultBody", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);

    utility->resultBody(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->result) {
      map_put(entryCtx, "result", fhMap({{"body", ctx->result->body}}));
    }
    return Value::undef();
  });
}

static void resultHeadersBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("resultHeaders-basic", rs::get_spec(primary(), {"resultHeaders", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);

    utility->resultHeaders(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->result) {
      map_put(entryCtx, "result", fhMap({{"headers", ctx->result->headers}}));
    }
    return Value::undef();
  });
}

// --- transformRequest / transformResponse -----------------------------------

static void transformRequestBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("transformRequest-basic", rs::get_spec(primary(), {"transformRequest", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);

    Value result = utility->transformRequest(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->spec) {
      Value specMap = Helpers::toMapAny(getp(entryCtx, "spec"));
      if (specMap.is_map()) map_put(specMap, "step", Value(ctx->spec->step));
    }
    return result;
  });
}

static void transformResponseBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  rs::runset("transformResponse-basic", rs::get_spec(primary(), {"transformResponse", "basic"}),
             [&](const Value& entry) -> Value {
    Value ctxmap = Helpers::toMapAny(getp(entry, "ctx"));
    CtxPtr ctx = rs::make_ctx_from_map(ctxmap, c, utility);

    Value result = utility->transformResponse(ctx);

    Value entryCtx = Helpers::toMapAny(getp(entry, "ctx"));
    if (entryCtx.is_map() && ctx->spec) {
      Value specMap = Helpers::toMapAny(getp(entryCtx, "spec"));
      if (specMap.is_map()) map_put(specMap, "step", Value(ctx->spec->step));
    }
    return result;
  });
}

int main() {
  T_RUN(exists);
  T_RUN(cleanBasic);
  T_RUN(doneBasic);
  T_RUN(makeErrorBasic);
  T_RUN(makeErrorNoThrow);
  T_RUN(featureAddBasic);
  T_RUN(featureHookBasic);
  T_RUN(featureInitBasic);
  T_RUN(featureInitInactive);
  T_RUN(fetcherLive);
  T_RUN(fetcherBlockedTestMode);
  T_RUN(makeContextBasic);
  T_RUN(makeFetchDefBasic);
  T_RUN(makeFetchDefWithBody);
  T_RUN(makeOptionsBasic);
  T_RUN(makeRequestBasic);
  T_RUN(makeResponseBasic);
  T_RUN(makeResultBasic);
  T_RUN(makeResultNoSpec);
  T_RUN(makeResultNoResult);
  T_RUN(makeSpecBasic);
  T_RUN(makePointBasic);
  T_RUN(makeUrlBasic);
  T_RUN(operatorBasic);
  T_RUN(paramBasic);
  T_RUN(prepareAuthBasic);
  T_RUN(prepareBodyBasic);
  T_RUN(prepareHeadersBasic);
  T_RUN(prepareMethodBasic);
  T_RUN(prepareParamsBasic);
  T_RUN(preparePathBasic);
  T_RUN(prepareQueryBasic);
  T_RUN(resultBasicBasic);
  T_RUN(resultBodyBasic);
  T_RUN(resultHeadersBasic);
  T_RUN(transformRequestBasic);
  T_RUN(transformResponseBasic);
  return sdktest::summary("primary_utility_test");
}
