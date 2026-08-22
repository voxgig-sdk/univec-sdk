// Univec SDK — offline feature-test harness (mirrors java
// test/FeatureHarness.java). Drives features through a faithful miniature of
// the real operation pipeline against a configurable mock transport.

#ifndef SDK_TEST_HARNESS_HPP
#define SDK_TEST_HARNESS_HPP

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "../core/sdk.hpp"
#include "testlib.hpp"

namespace sdk {
namespace fh {

using FetcherFn = std::function<Value(CtxPtr, const std::string&, const Value&)>;

// fhMap — small struct Value map builder for test options.
inline Value fhMap(std::initializer_list<std::pair<std::string, Value>> il) { return vmap(il); }

// fhHasFeature — true when this SDK was generated with the named feature.
inline bool fhHasFeature(const std::string& name) {
  Value config = makeConfig();
  Value fm = Helpers::toMapAny(getp(config, "feature"));
  return fm.is_map() && !getp(fm, name).is_undef();
}

// FhClock — a deterministic virtual clock (now() advances only via sleep()).
struct FhClock {
  long long t = 0;
  long long now() const { return t; }
  void sleep(int ms) { t += ms; }
  void advance(int ms) { t += ms; }
  // struct-func views for injecting into feature options.
  Value nowFn() {
    FhClock* self = this;
    vs::Injector fn = [self](vs::Injection&, const Value&, const std::string&,
                             const Value&) -> Value { return Value(self->t); };
    return Value(fn);
  }
  Value sleepFn() {
    FhClock* self = this;
    vs::Injector fn = [self](vs::Injection&, const Value& args, const std::string&,
                             const Value&) -> Value {
      Value ms = vs::getelem(args, Value(int64_t(0)));
      self->t += ms.is_number() ? static_cast<int>(ms.as_int()) : 0;
      return Value::undef();
    };
    return Value(fn);
  }
};

// fhResponse — a transport-shaped response the pipeline understands.
inline Value fhResponse(int status, const Value& data, const Value& headers) {
  Value h = vmap();
  if (headers.is_map()) {
    for (const auto& kv : *headers.as_map()) {
      std::string lk = kv.first;
      for (auto& c : lk) c = static_cast<char>(std::tolower((unsigned char)c));
      map_put(h, lk, kv.second);
    }
  }
  Value out = vmap();
  map_put(out, "status", Value(status));
  map_put(out, "statusText", Value(status >= 400 ? "ERR" : "OK"));
  map_put(out, "body", Value("not-used"));
  map_put(out, "json", json_thunk(data));
  map_put(out, "headers", h);
  return out;
}

// FhRecorder — a mock transport recording every call.
struct FhRecorder {
  std::vector<Value> calls;
  std::function<Value(int, const Value&)> reply;

  Value fetch(CtxPtr ctx, const std::string& url, const Value& fetchdef) {
    Value call = vmap();
    map_put(call, "url", Value(url));
    map_put(call, "fetchdef", fetchdef);
    calls.push_back(call);
    if (reply) return reply((int)calls.size(), fetchdef);
    Value data = vmap();
    map_put(data, "ok", Value(true));
    map_put(data, "n", Value((int)calls.size()));
    return fhResponse(200, data, Value::undef());
  }
  Value headers(int i) {
    Value fetchdef = Helpers::toMapAny(getp(calls[i], "fetchdef"));
    Value h = Helpers::toMapAny(getp(fetchdef, "headers"));
    return h.is_map() ? h : vmap();
  }
  Value fetchdef(int i) {
    Value f = Helpers::toMapAny(getp(calls[i], "fetchdef"));
    return f.is_map() ? f : vmap();
  }
  std::string url(int i) {
    Value u = getp(calls[i], "url");
    return u.is_string() ? u.as_string() : "";
  }
};

// FhFeature — a feature instance paired with its init options.
struct FhFeature {
  FeaturePtr f;
  Value options;
};
inline FhFeature fhF(FeaturePtr f, const Value& options) { return FhFeature{f, options}; }

// FhOpSpec — one operation request (builder style).
struct FhOpSpec {
  std::string entity;
  std::string op;
  std::string method;
  std::string path;
  Value query = Value::undef();
  Value headers = Value::undef();
  Value body = Value::undef();
  Value ctrl = Value::undef();

  FhOpSpec& setOp(const std::string& v) { op = v; return *this; }
  FhOpSpec& setEntity(const std::string& v) { entity = v; return *this; }
  FhOpSpec& setMethod(const std::string& v) { method = v; return *this; }
  FhOpSpec& setPath(const std::string& v) { path = v; return *this; }
  FhOpSpec& setQuery(const Value& v) { query = v; return *this; }
  FhOpSpec& setHeaders(const Value& v) { headers = v; return *this; }
  FhOpSpec& setBody(const Value& v) { body = v; return *this; }
  FhOpSpec& setCtrl(const Value& v) { ctrl = v; return *this; }
};
inline FhOpSpec fhOp(const std::string& op) { FhOpSpec s; s.op = op; return s; }

struct FhOpResult {
  bool ok = false;
  Value data = Value::undef();
  SdkErrorPtr err;
  ResultPtr result;
  CtxPtr ctx;
};

inline std::string fhDefaultMethod(const std::string& op) {
  if (op == "create") return "POST";
  if (op == "update") return "PATCH";
  if (op == "remove") return "DELETE";
  return "GET";
}

inline std::string urlencode(const std::string& s) {
  static const char* hex = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : s) {
    if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') out.push_back((char)c);
    else { out.push_back('%'); out.push_back(hex[c >> 4]); out.push_back(hex[c & 15]); }
  }
  return out;
}

inline std::string fhBuildUrl(const SpecPtr& spec) {
  // sorted-key query for stability
  std::vector<std::string> keys;
  if (spec->query.is_map()) {
    for (const auto& k : Struct::keysof(spec->query)) {
      if (!is_nullish(getp(spec->query, k))) keys.push_back(k);
    }
  }
  std::string qs;
  for (const auto& k : keys) {
    if (!qs.empty()) qs += "&";
    qs += urlencode(k) + "=" + urlencode(Struct::stringify(getp(spec->query, k)));
  }
  std::string url = spec->base + spec->path;
  if (!qs.empty()) url += "?" + qs;
  return url;
}

struct FhHarness {
  std::shared_ptr<UnivecSDK> client;
  UtilityPtr utility;
  CtxPtr rootctx;
  std::string base = "http://api.test";

  FhOpResult fail(CtxPtr ctx, SdkErrorPtr err) {
    ctx->ctrl->err = err;
    utility->featureHook(ctx, "PreUnexpected");
    FhOpResult out;
    out.ok = false;
    out.err = err;
    out.result = ctx->result;
    out.ctx = ctx;
    return out;
  }

  void populateResult(CtxPtr ctx, const Value& response, SdkErrorPtr fetchErr) {
    auto result = std::make_shared<Result>();
    ctx->result = result;

    if (fetchErr) { result->err = fetchErr; return; }
    if (!response.is_map()) {
      result->err = ctx->makeError("request_no_response", "response: undefined");
      return;
    }
    auto resp = std::make_shared<Response>(response);
    result->status = resp->status;
    result->statusText = resp->statusText;
    if (resp->headers.is_map()) result->headers = resp->headers;
    if (resp->jsonFunc) result->body = resp->jsonFunc();
    result->resdata = result->body;

    if (result->status >= 400) {
      result->err = ctx->makeError("request_status",
          "request: " + std::to_string(result->status) + ": " + result->statusText);
    } else if (resp->err) {
      result->err = resp->err;
    }
    if (!result->err) result->ok = true;
  }

  FhOpResult op(const FhOpSpec& o) {
    std::string entity = o.entity.empty() ? "widget" : o.entity;
    std::string opname = o.op.empty() ? "load" : o.op;
    std::string method = o.method.empty() ? fhDefaultMethod(opname) : o.method;
    Value ctrl = o.ctrl.is_map() ? o.ctrl : vmap();

    CtxSpec cs;
    cs.setOpname(opname);
    cs.ctrlMap = ctrl;
    CtxPtr ctx = utility->makeContext(cs, rootctx);
    Value opdef = vmap();
    map_put(opdef, "entity", Value(entity));
    map_put(opdef, "name", Value(opname));
    ctx->op = std::make_shared<Operation>(opdef);

    utility->featureHook(ctx, "PostConstructEntity");

    utility->featureHook(ctx, "PrePoint");
    if (ctx->out.pointError) {
      return fail(ctx, ctx->out.pointError);
    }

    utility->featureHook(ctx, "PreSpec");
    std::string path = o.path.empty() ? "/" + entity : o.path;
    Value headers = vmap();
    if (o.headers.is_map()) for (const auto& kv : *o.headers.as_map()) map_put(headers, kv.first, kv.second);
    Value query = vmap();
    if (o.query.is_map()) for (const auto& kv : *o.query.as_map()) map_put(query, kv.first, kv.second);
    Value specmap = vmap();
    map_put(specmap, "method", Value(method));
    map_put(specmap, "base", Value(base));
    map_put(specmap, "path", Value(path));
    map_put(specmap, "headers", headers);
    map_put(specmap, "query", query);
    map_put(specmap, "step", Value("start"));
    ctx->spec = std::make_shared<Spec>(specmap);
    if (!is_nullish(o.body)) ctx->spec->body = o.body;

    utility->featureHook(ctx, "PreRequest");
    ctx->spec->url = fhBuildUrl(ctx->spec);

    Value fetchdef = vmap();
    map_put(fetchdef, "url", Value(ctx->spec->url));
    map_put(fetchdef, "method", Value(ctx->spec->method));
    map_put(fetchdef, "headers", ctx->spec->headers);
    if (!is_nullish(ctx->spec->body)) map_put(fetchdef, "body", ctx->spec->body);

    Value response = Value::undef();
    SdkErrorPtr fetchErr;
    if (ctx->out.request) {
      // a feature short-circuited the request with a cached Response
      response = vmap();
      map_put(response, "status", Value(ctx->out.request->status));
    } else {
      try {
        response = utility->fetcher(ctx, ctx->spec->url, fetchdef);
      } catch (const SdkErrorPtr& e) {
        fetchErr = e;
      }
    }
    if (response.is_map()) ctx->response = std::make_shared<Response>(response);

    utility->featureHook(ctx, "PreResponse");
    populateResult(ctx, response, fetchErr);
    utility->featureHook(ctx, "PreResult");
    utility->featureHook(ctx, "PreDone");

    if (ctx->result && ctx->result->ok) {
      FhOpResult out;
      out.ok = true;
      out.data = ctx->result->resdata;
      out.result = ctx->result;
      out.ctx = ctx;
      return out;
    }

    SdkErrorPtr err;
    if (ctx->result && ctx->result->err) err = ctx->result->err;
    else err = ctx->makeError("op_failed", "operation failed");
    return fail(ctx, err);
  }
};

// fhMake — construct the harness: a test-mode client, an isolated utility
// whose fetcher is the mock server, and the requested features initialised.
inline std::shared_ptr<FhHarness> fhMake(FetcherFn server, std::vector<FhFeature> features) {
  auto client = UnivecSDK::testSDK();
  client->features.clear();

  UtilityPtr utility = client->getUtility();
  std::shared_ptr<FhRecorder> rec;
  if (!server) {
    rec = std::make_shared<FhRecorder>();
    server = [rec](CtxPtr ctx, const std::string& url, const Value& fd) { return rec->fetch(ctx, url, fd); };
  }
  utility->fetcher = server;

  CtxSpec cs;
  cs.client = client.get();
  cs.utility = utility;
  CtxPtr rootctx = utility->makeContext(cs, client->getRootCtx());

  for (auto& fs : features) {
    Value fopts = vmap();
    map_put(fopts, "active", Value(true));
    if (fs.options.is_map()) for (const auto& kv : *fs.options.as_map()) map_put(fopts, kv.first, kv.second);
    fs.f->init(rootctx, fopts);
    client->features.push_back(fs.f);
  }

  utility->featureHook(rootctx, "PostConstruct");

  auto h = std::make_shared<FhHarness>();
  h->client = client;
  h->utility = utility;
  h->rootctx = rootctx;
  return h;
}

inline std::string fhErrCode(const SdkErrorPtr& err) { return err ? err->code : ""; }

} // namespace fh
} // namespace sdk

#endif // SDK_TEST_HARNESS_HPP
