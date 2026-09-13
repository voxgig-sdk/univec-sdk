// Univec SDK — drives the primary utility functions against the shared
// test.json spec (../.sdk/test/test.json, section "primary") through the
// VENDORED omni runner (test/omni_resolver.hpp over test/vendor/omni).
// Mirrors java test/PrimaryUtilityTest.java + tm/go/test/primary_utility_test.go.
//
// Subjects receive omni's native argument list: a ctx entry arrives as
// args[0], a MAP — resolver::omni_ctx builds the typed Context a generated
// utility takes, and resolver::omni_sync_ctx writes the observable ctx
// state back for `match: {ctx: ...}` assertions (which the resolver has
// rewritten to `match: {args: [...]}`; see its decision 4). A failing entry
// throws omni::OmniError naming the entry, which T_RUN records.

#include <algorithm>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "omni_resolver.hpp"
#include "harness.hpp"

using namespace sdk;
using namespace sdk::fh;
namespace res = sdk::resolver;

static const char* TEST_JSON_FILE = "../.sdk/test/test.json";

// One corpus runner for the whole binary. Its client is the runner's own
// (only a DEF.client entry would use it); each test still builds the client
// it drives, because several of them mutate it.
static res::Run& primaryRun() {
  static res::Run run =
      res::makeRunner(TEST_JSON_FILE, UnivecSDK::testSDK())
          .runner("primary", Value::undef());
  return run;
}

static std::shared_ptr<UnivecSDK> client() { return UnivecSDK::testSDK(); }

// args[0], or no value at all (an entry with no in/args/ctx, which this
// port's omni delivers as one absent argument).
static Value arg0(std::vector<Value>& args) {
  return args.empty() ? Value::undef() : args[0];
}

// Every corpus section this binary ASKED to run, whether or not the guard
// below let it through. corpusCoverage() compares it against the fixture,
// which is the only way a section that NO test names can be noticed: the
// per-section guard cannot fire for a call nobody wrote.
static std::set<std::string>& drivenSections() {
  static std::set<std::string> names;
  return names;
}

// Run one corpus section's `basic` group, failing LOUDLY when it would run
// ZERO cases. A renamed section, a fixture that failed to compile, or an
// empty set used to report PASS while running no assertions at all — the
// whole point of a shared oracle lost without a single red test. (The guard
// lives here rather than in the runner, which is vendored verbatim; the
// shared corpus is a v0 spec, and v0 tolerates an empty set.)
static void runsection(const std::string& name, const res::Subject& subject) {
  drivenSections().insert(name);

  Value section = Helpers::toMapAny(primaryRun().set(name));
  if (!section.is_map()) {
    sdktest::record_fail(name, "test corpus section \"" + name +
                                   "\" missing - check .sdk/test/primary/");
    return;
  }
  Value basic = Helpers::toMapAny(getp(section, Value("basic")));
  Value set = basic.is_map() ? getp(basic, Value("set")) : Value::undef();
  if (!set.is_list()) {
    sdktest::record_fail(name, "test corpus section \"" + name +
                                   "\" has no basic.set list - zero cases would run");
    return;
  }
  if (set.as_list()->empty()) {
    sdktest::record_fail(name, "test corpus section \"" + name +
                                   "\" is EMPTY - zero cases would run");
    return;
  }
  sdktest::checks()++;
  primaryRun().runsetflags(name, basic, true, subject);
}

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

// The shared corpus drives the same function over four shapes the stub above
// cannot reach — an empty map, a bare string, a list — and asserts the value
// that comes back, not merely that one does. (The ts and java peers pair the
// stub with this section the same way.)
static void cleanCorpus() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("clean", [&](std::vector<Value>& args) -> Value {
    if (2 != args.size()) {
      throw std::runtime_error("clean: expected 2 args, got " + std::to_string(args.size()));
    }
    CtxPtr ctx = res::omni_ctx(args[0], c, utility);
    return utility->clean(ctx, args[1]);
  });
}

// --- done -------------------------------------------------------------------

static void doneBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("done", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    return utility->done(ctx);
  });
}

// --- makeError --------------------------------------------------------------

static void makeErrorBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("makeError", [&](std::vector<Value>& args) -> Value {
    Value ctxmap = Helpers::toMapAny(arg0(args));
    if (!ctxmap.is_map()) ctxmap = vmap();
    CtxPtr ctx = res::omni_ctx(ctxmap, c, utility);

    SdkErrorPtr err;
    if (args.size() > 1) {
      err = errFromMap(Helpers::toMapAny(args[1]));
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
  runsection("makeContext", [&](std::vector<Value>& args) -> Value {
    Value in = Helpers::toMapAny(arg0(args));
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
  runsection("makeOptions", [&](std::vector<Value>& args) -> Value {
    Value in = Helpers::toMapAny(arg0(args));
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
  runsection("makeRequest", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    ctx->options = c->optionsMap();

    utility->makeRequest(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return Value::undef();
  });
}

// --- makeResponse -----------------------------------------------------------

static void makeResponseBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("makeResponse", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);

    utility->makeResponse(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
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
  // omni stamps ctx.client with PRESENCE, not identity, so a DEF-built
  // client cannot be read back out of the ctx map: this section's
  // specially-optioned client is constructed here (resolver decision 5).
  Value setupOpts = rs::get_spec(primaryRun().spec, {"makeSpec", "DEF", "setup", "a"});
  auto specClient = UnivecSDK::testSDK(Value::undef(), setupOpts);
  UtilityPtr specUtility = specClient->getUtility();

  runsection("makeSpec", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), specClient, specUtility);
    ctx->options = specClient->optionsMap();

    specUtility->makeSpec(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return Value::undef();
  });
}

// --- makePoint --------------------------------------------------------------

// Corpus-driven, like ts and java. Each entry carries the WHOLE endpoint
// lookup in its ctx — the API config, the entity it hangs off, the options
// that gate the operation, and the match/reqmatch that select among several
// points — which rs::make_ctx_from_map materialises (the entity cannot
// travel as a plain map: Context resolves the op through Entity::getName).
// Four of the seven entries assert a chosen point; three assert a REFUSAL
// the retired stub could not reach at all, since it only ever asserted that
// some point came back. TS returns the error AS the value while cpp throws
// an SdkErrorPtr, so the error is normalised to a map carrying its code
// rather than forking the fixture per language.
static void makePointBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("makePoint", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    try {
      return utility->makePoint(ctx);
    } catch (const SdkErrorPtr& err) {
      return fhMap({{"code", Value(err->code)}});
    }
  });
}

// --- makeUrl ----------------------------------------------------------------

static void makeUrlBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("makeUrl", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    if (!ctx->result) ctx->result = std::make_shared<Result>(vmap());
    return Value(utility->makeUrl(ctx));
  });
}

// --- operator ---------------------------------------------------------------

static void operatorBasic() {
  runsection("operator", [&](std::vector<Value>& args) -> Value {
    Value in = Helpers::toMapAny(arg0(args));
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
  runsection("param", [&](std::vector<Value>& args) -> Value {
    if (args.size() < 2) return Value::undef();

    Value ctxmap = Helpers::toMapAny(arg0(args));
    if (!ctxmap.is_map()) ctxmap = vmap();
    CtxPtr ctx = res::omni_ctx(ctxmap, c, utility);
    Value paramdef = args[1];

    Value result = utility->param(ctx, paramdef);

    res::omni_sync_ctx(arg0(args), ctx);
    return result;
  });
}

// --- prepareAuth ------------------------------------------------------------

static void prepareAuthBasic() {
  // Constructed at the call site: see the note on makeSpec above.
  Value setupOpts = rs::get_spec(primaryRun().spec, {"prepareAuth", "DEF", "setup", "a"});
  auto authClient = UnivecSDK::testSDK(Value::undef(), setupOpts);
  UtilityPtr authUtility = authClient->getUtility();

  runsection("prepareAuth", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), authClient, authUtility);

    authUtility->prepareAuth(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return Value::undef();
  });
}

// --- prepareBody / prepareHeaders / prepareMethod / prepareParams -----------

static void prepareBodyBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("prepareBody", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    return utility->prepareBody(ctx);
  });
}

static void prepareHeadersBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("prepareHeaders", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    return utility->prepareHeaders(ctx);
  });
}

static void prepareMethodBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("prepareMethod", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    // An op the API does not define resolves NO method; ts answers
    // undefined there and C++ answers "" — both are "no value" to the
    // corpus (the go subject does the same).
    std::string method = utility->prepareMethod(ctx);
    return method.empty() ? Value::undef() : Value(method);
  });
}

static void prepareParamsBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("prepareParams", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    return utility->prepareParams(ctx);
  });
}

// --- preparePath ------------------------------------------------------------

static void preparePathBasic() {
  // Was hand-written cases that had drifted out of the shared corpus (the
  // preparePath fixture shipped as an empty `set: []`).
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("preparePath", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    return Value(utility->preparePath(ctx));
  });
}

// --- prepareQuery -----------------------------------------------------------

static void prepareQueryBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("prepareQuery", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);
    return utility->prepareQuery(ctx);
  });
}

// --- resultBasic / resultBody / resultHeaders -------------------------------

static void resultBasicBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("resultBasic", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);

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
  runsection("resultBody", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);

    utility->resultBody(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return Value::undef();
  });
}

static void resultHeadersBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("resultHeaders", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);

    utility->resultHeaders(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return Value::undef();
  });
}

// --- transformRequest / transformResponse -----------------------------------

static void transformRequestBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("transformRequest", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);

    Value result = utility->transformRequest(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return result;
  });
}

static void transformResponseBasic() {
  auto c = client();
  UtilityPtr utility = c->getUtility();
  runsection("transformResponse", [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(arg0(args), c, utility);

    Value result = utility->transformResponse(ctx);

    res::omni_sync_ctx(arg0(args), ctx);
    return result;
  });
}

// --- whole-corpus coverage --------------------------------------------------

// Sections under `primary` that are NOT this SDK's pipeline surface, with the
// reason each is exempt. `check` is omni's OWN runner fixture (it comes from
// .sdk/test/struct/test.aon, which the corpus build merges into primary); no
// port drives it from a primary suite.
static const std::vector<std::string>& notThisSuite() {
  static const std::vector<std::string> names = {"check"};
  return names;
}

static std::string joinnames(const std::vector<std::string>& names) {
  std::string out;
  for (const auto& name : names) {
    if (!out.empty()) out += ", ";
    out += name;
  }
  return out;
}

// The guard the PER-SECTION one cannot be. runsection() only fires for a
// section some test actually names, so a section no test names is invisible
// to it: `clean` (4 entries) and `makePoint` (7) sat undriven behind
// hand-written stubs while this binary reported "67 cases driven" — a number
// that was the sum of the sections it happened to call, and so could not
// tell full coverage from partial. Comparing the fixture against what was
// actually driven is what makes that line evidence.
static void corpusCoverage() {
  Value spec = primaryRun().spec;
  ASSERT_TRUE(spec.is_map(), "primary corpus did not resolve - no coverage to check");
  if (!spec.is_map()) return;

  std::vector<std::string> sections = Struct::keysof(spec);
  ASSERT_TRUE(!sections.empty(), "primary corpus has NO sections - check ../.sdk/test/test.json");

  std::vector<std::string> undriven;
  std::vector<std::string> staleskip;

  for (const auto& name : sections) {
    Value section = Helpers::toMapAny(getp(spec, Value(name)));
    Value basic = section.is_map() ? Helpers::toMapAny(getp(section, Value("basic"))) : Value::undef();
    Value set = basic.is_map() ? getp(basic, Value("set")) : Value::undef();
    bool hascases = set.is_list() && !set.as_list()->empty();

    const auto& exempt = notThisSuite();
    if (std::find(exempt.begin(), exempt.end(), name) != exempt.end()) {
      // The exemption has to keep earning itself: a name that lost its cases
      // (or was renamed away) no longer needs one, and a list nobody prunes
      // is how the next hole gets excused.
      if (!hascases) staleskip.push_back(name);
      continue;
    }

    if (hascases && 0 == drivenSections().count(name)) undriven.push_back(name);
  }

  ASSERT_TRUE(undriven.empty(),
              "primary corpus sections carry cases that NO test drives: " + joinnames(undriven) +
                  " - add a runsection() call; until then the \"cases driven\" count is not coverage");
  ASSERT_TRUE(staleskip.empty(),
              "these names are exempt from the coverage check but no longer carry cases: " +
                  joinnames(staleskip) + " - drop them from notThisSuite()");
}

int main() {
  T_RUN(exists);
  T_RUN(cleanBasic);
  T_RUN(cleanCorpus);
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
  // LAST: it reads what every test above actually drove.
  T_RUN(corpusCoverage);
  std::cout << "primary corpus: " << res::cases() << " cases driven\n";
  return sdktest::summary("primary_utility_test");
}
