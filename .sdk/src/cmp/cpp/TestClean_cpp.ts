import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
  entityCollection,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import { cppVarName } from './utility_cpp'


// The canary sweep (see TestClean_ts). cpp has no reflection, so the
// operations the ts sweep discovers from the client are emitted from the
// model, each with the path parameters its config points declare, and the
// transport is scripted through `system.fetch`, the seam a closed options
// union leaves for it.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const ProjectName = model.const.Name

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  const configEntity = configDefinition(model, target.name).def.entity || {}

  const rank: Record<string, number> = { list: 0, load: 1 }
  const candidates: Candidate[] = []
  each(entityCollection(model))
    .filter((e: any) => false !== e.active)
    .forEach((entity: any) => {
      const ops = Object.keys(entity.op || {})
        .filter((op) => ['list', 'load', 'create', 'update', 'patch', 'remove'].includes(op))
        .sort((a, b) => (rank[a] ?? 2) - (rank[b] ?? 2))
      for (const op of ops) {
        candidates.push({
          name: entity.name + '.' + op, accessor: cppVarName(entity.name), op,
          params: pointParams(configEntity[entity.name]?.op?.[op]),
        })
      }
    })

  File({ name: 'clean_test.cpp' }, () => Content(render(ProjectName, auth, candidates)))
})


type Candidate = { name: string, accessor: string, op: string, params: string[] }


// Every path parameter an operation's points declare, as the generated
// config carries them (points[].args.params[].name).
function pointParams(opdef: any): string[] {
  const names: string[] = []
  for (const point of opdef?.points || []) {
    for (const p of point?.args?.params || []) {
      if ('string' === typeof p?.name && !names.includes(p.name)) names.push(p.name)
    }
  }
  return names
}


function candidate(ProjectName: string, c: Candidate): string {
  const call = 'list' === c.op
    ? `auto ents = ent->list(m, ctrl);
        Value out = vlist();
        for (const auto& e : ents) out.as_list()->push_back(e->data());`
    : `Value out = ent->${c.op}(m, ctrl)->data();`
  return `    {"${c.name}", {${c.params.map(cppstr).join(', ')}},
     [](${ProjectName}SDK& c, const Value& m, const Value& ctrl, Value* match) -> Value {
      auto ent = c.${c.accessor}();
      try {
        ${call}
        if (match) *match = ent->match();
        return out;
      } catch (...) {
        if (match) *match = ent->match();
        throw;
      }
    },
     [](${ProjectName}SDK& c, const Value& m, const Value& callopts) -> std::vector<Value> {
      return c.${c.accessor}()->stream(${cppstr(c.op)}, m, callopts);
    }},`
}


function render(
  ProjectName: string,
  auth: { suppressed: boolean, where: string, name: string, basic: boolean },
  candidates: Candidate[],
): string {
  return `// Generated canary sweep: no credential leaves this SDK in any form.
// Mirrors test/clean.test.ts in the ts reference. Do not hand-edit.

#include <functional>
#include <iostream>
#include <stdexcept>
#include <map>
#include <string>
#include <vector>

#include "testlib.hpp"

using namespace sdk;

// Generated: the credential's wire placement is fixed when the SDK is built.
static const bool AUTH_SUPPRESSED = ${auth.suppressed ? 'true' : 'false'};
static const std::string AUTH_WHERE = ${cppstr(auth.where)};
static const std::string AUTH_NAME = ${cppstr(auth.name)};

static const std::string CANARY_APIKEY = "CANARY-APIKEY-k9x2m7q4p1";
static const std::string CANARY_SECRET = "CANARY-SECRET-w3e8r5t2y6";
static const std::string CANARY_HEADER = "CANARY-HEADER-z1x4c7v0b3";
static const std::string CANARY_VALUE = "CANARY-VALUE-n5m8b2v9c4";

static const std::string MASK = "[redacted]";


struct Sink {
  std::string name;
  std::string text;
};


// Every form a canary can travel in.
static std::vector<std::string> canaryForms() {
  std::vector<std::string> out;
  for (const std::string& v : {CANARY_APIKEY, CANARY_SECRET, CANARY_HEADER, CANARY_VALUE}) {
    out.push_back(v);
    out.push_back(util::cleanBase64(v));
    out.push_back(Struct::escurl(Value(v)));
  }
  out.push_back(util::cleanBase64(CANARY_APIKEY + ":" + CANARY_SECRET));
  return out;
}


static std::vector<std::string> leaks(const std::string& text) {
  std::vector<std::string> out;
  for (const auto& f : canaryForms()) {
    if (std::string::npos != text.find(f)) out.push_back(f);
  }
  return out;
}


// Header maps keep the caller's spelling; the assertion should not care.
static Value header(const Value& map, const std::string& name) {
  if (!map.is_map()) return Value::undef();
  std::string lname = name;
  for (auto& c : lname) c = static_cast<char>(std::tolower((unsigned char)c));
  for (const auto& kv : *map.as_map()) {
    std::string k = kv.first;
    for (auto& c : k) c = static_cast<char>(std::tolower((unsigned char)c));
    if (k == lname) return kv.second;
  }
  return Value::undef();
}


static bool endsWith(const std::string& s, const std::string& suf) {
  return s.size() >= suf.size() && 0 == s.compare(s.size() - suf.size(), suf.size(), suf);
}


static void addForms(std::vector<Sink>& sinks, const std::string& name, const Value& val) {
  sinks.push_back({name + ":json", vs::jsonify(val, 0)});
  sinks.push_back({name + ":string", Struct::stringify(val)});
}


static void addError(std::vector<Sink>& sinks, const std::string& name, const SdkErrorPtr& err) {
  sinks.push_back({name + ":what", std::string(err->what())});
  sinks.push_back({name + ":string", err->to_string()});
  addForms(sinks, name + ":value", err->toValue());
  addForms(sinks, name + ":spec", err->spec);
  addForms(sinks, name + ":result", err->result);
}


// Captures the serialised context from inside the pipeline: what a hook
// author would hand to a logger.
class CaptureFeature : public BaseFeature {
public:
  std::vector<Sink>* sinks;
  explicit CaptureFeature(std::vector<Sink>* sinks_)
      : BaseFeature("capture", "0.0.1", true), sinks(sinks_) {}
  void preRequest(CtxPtr ctx) override { sinks->push_back({"ctx@PreRequest", ctx->to_string()}); }
  void preResponse(CtxPtr ctx) override { sinks->push_back({"ctx@PreResponse", ctx->to_string()}); }
  void preUnexpected(CtxPtr ctx) override { sinks->push_back({"ctx@PreUnexpected", ctx->to_string()}); }
};


// A feature that throws from inside the pipeline, quoting the request it
// saw: an exception makeError never handled. Its variant throws again from
// PreUnexpected, which makeError fires once it has cleaned its own error.
class ThrowFeature : public BaseFeature {
public:
  bool unexpected;
  explicit ThrowFeature(bool unexpected_ = false)
      : BaseFeature("throwhook", "0.0.1", true), unexpected(unexpected_) {}
  void preResponse(CtxPtr ctx) override {
    throw std::runtime_error("hook saw " + vs::jsonify(ctx->spec ? ctx->spec->toValue() : Value::undef(), 0));
  }
  void preUnexpected(CtxPtr ctx) override {
    if (unexpected) {
      throw std::runtime_error("hook saw " + vs::jsonify(ctx->spec ? ctx->spec->toValue() : Value::undef(), 0));
    }
  }
};


// Features that fail the operation with the SDK's own error, whose code
// quotes a registered value: one refuses it as rbac does, and records the
// error PreUnexpected hands a hook; the other throws it.
class DenyFeature : public BaseFeature {
public:
  std::vector<Sink>* sinks;
  explicit DenyFeature(std::vector<Sink>* sinks_)
      : BaseFeature("denyhook", "0.0.1", true), sinks(sinks_) {}
  void prePoint(CtxPtr ctx) override {
    ctx->out.pointError = ctx->makeError("denied:" + CANARY_VALUE, "denied");
  }
  void preUnexpected(CtxPtr ctx) override {
    if (ctx->ctrl->err) addError(*sinks, "error", ctx->ctrl->err);
  }
};

class RaiseFeature : public BaseFeature {
public:
  RaiseFeature() : BaseFeature("raisehook", "0.0.1", true) {}
  void preResponse(CtxPtr) override {
    throw std::make_shared<SdkError>("raised:" + CANARY_VALUE, "raised", nullptr);
  }
};


// A stream whose producer fails while the caller consumes it, quoting a
// credential.
class StreamThrowFeature : public BaseFeature {
public:
  StreamThrowFeature() : BaseFeature("streamthrow", "0.0.1", true) {}
  void preDone(CtxPtr ctx) override {
    if (!ctx->result) return;
    ctx->result->stream = []() -> std::vector<Value> {
      throw std::runtime_error("stream saw " + CANARY_APIKEY);
    };
  }
};


// A stream that succeeds, so the pipeline's terminal step never runs.
class StreamOkFeature : public BaseFeature {
public:
  StreamOkFeature() : BaseFeature("streamok", "0.0.1", true) {}
  void preDone(CtxPtr ctx) override {
    if (!ctx->result) return;
    std::vector<Value> items;
    Value data = ctx->result->resdata;
    if (data.is_list()) {
      for (const auto& item : *data.as_list()) items.push_back(item);
    } else if (!is_nullish(data)) {
      items.push_back(data);
    }
    ctx->result->stream = [items]() { return items; };
  }
};


// A sink callable: records every form of the record it receives.
static Value capture(std::vector<Sink>* sinks, const std::string& name, int at) {
  vs::Injector fn = [sinks, name, at](vs::Injection&, const Value& args, const std::string&,
                                      const Value&) -> Value {
    addForms(*sinks, name, vs::getelem(args, Value(int64_t(at))));
    return Value::undef();
  };
  return Value(fn);
}


static Value response(int status, const Value& data, const Value& headers) {
  Value h = vmap({{"content-type", Value("application/json")}});
  if (headers.is_map()) {
    for (const auto& kv : *headers.as_map()) map_put(h, kv.first, kv.second);
  }
  Value out = vmap();
  map_put(out, "status", Value(status));
  map_put(out, "statusText", Value(status < 400 ? "OK" : "ERR"));
  map_put(out, "body", Value(vs::jsonify(data, 0)));
  map_put(out, "json", json_thunk(data));
  map_put(out, "headers", h);
  return out;
}


struct Scenario {
  std::string name;
  std::function<Value(const std::string&, const Value&)> respond;
};


static std::vector<Scenario> scenarios() {
  return {
    {"ok", [](const std::string&, const Value&) {
      return response(200, vmap({{"id", Value("i1")}, {"name", Value("n1")}}),
                      vmap({{"x-session-token", Value("RESP-TOKEN-a1b2c3d4e5")}}));
    }},
    {"notfound", [](const std::string&, const Value&) {
      return response(404, vmap({{"error", Value("no such record")}}), Value::undef());
    }},
    {"server", [](const std::string&, const Value&) {
      return response(500, vmap({{"error", Value("boom")}}), Value::undef());
    }},
    {"transport", [](const std::string& url, const Value&) -> Value {
      throw std::make_shared<SdkError>("fetch_fail",
        "socket hang up (URL was: \\"" + url + "\\")", nullptr);
    }},
    {"notjson", [](const std::string&, const Value&) {
      vs::Injector broken = [](vs::Injection&, const Value&, const std::string&,
                               const Value&) -> Value {
        throw std::make_shared<SdkError>("json_parse", "Unexpected token < in JSON", nullptr);
      };
      Value out = vmap();
      map_put(out, "status", Value(200));
      map_put(out, "statusText", Value("OK"));
      map_put(out, "body", Value("<html>"));
      map_put(out, "json", Value(broken));
      map_put(out, "headers", vmap());
      return out;
    }},
  };
}


static bool hasFeature(const std::string& name) {
  Value fm = Helpers::toMapAny(getp(sharedConfig(), "feature"));
  return fm.is_map() && !getp(fm, name).is_undef();
}


// Offline, as every generated suite is: the test OPTION resolves a required
// server variable to test-<name>, and installs no transport.
static Value offline(const Value& opts) {
  Value out = vmap();
  if (opts.is_map()) {
    for (const auto& kv : *opts.as_map()) map_put(out, kv.first, kv.second);
  }
  map_put(out, "test", vmap({{"active", Value(true)}}));
  return out;
}

// A client the sweep cannot build leaves nothing swept: a harness error, not
// a leak.
static std::shared_ptr<${ProjectName}SDK> construct(const Value& opts) {
  const std::string harness = "clean harness: the client could not be constructed, so nothing was swept: ";
  try {
    return std::make_shared<${ProjectName}SDK>(offline(opts));
  } catch (const SdkErrorPtr& e) {
    throw std::runtime_error(harness + e->msg);
  } catch (const std::exception& e) {
    throw std::runtime_error(harness + e.what());
  }
}

static std::shared_ptr<${ProjectName}SDK> makeSdk(const Scenario& scenario, std::vector<Sink>* sinks,
                                              const Value& cleanopts,
                                              FeaturePtr extra = nullptr,
                                              const Value& auth = Value::undef()) {
  Value feature = vmap();
  if (hasFeature("log")) {
    // The log feature hands [level, record] to its logger.
    map_put(feature, "log", vmap({{"active", Value(true)}, {"logger", capture(sinks, "log", 1)}}));
  }
  if (hasFeature("debug")) {
    map_put(feature, "debug", vmap({{"active", Value(true)}, {"onEntry", capture(sinks, "debug", 0)}}));
  }
  if (hasFeature("audit")) {
    map_put(feature, "audit", vmap({{"active", Value(true)}, {"sink", capture(sinks, "audit", 0)}}));
  }
  if (hasFeature("telemetry")) {
    map_put(feature, "telemetry", vmap({{"active", Value(true)}, {"exporter", capture(sinks, "telemetry", 0)}}));
  }
  if (hasFeature("cost")) {
    map_put(feature, "cost", vmap({{"active", Value(true)}, {"sink", capture(sinks, "cost", 0)}}));
  }
  if (hasFeature("metrics")) map_put(feature, "metrics", vmap({{"active", Value(true)}}));
  if (hasFeature("clienttrack")) map_put(feature, "clienttrack", vmap({{"active", Value(true)}}));

  Scenario sc = scenario;
  vs::Injector fetch = [sc](vs::Injection&, const Value& args, const std::string&,
                            const Value&) -> Value {
    Value url = vs::getelem(args, Value(int64_t(0)));
    Value fetchdef = vs::getelem(args, Value(int64_t(1)));
    return sc.respond(url.is_string() ? url.as_string() : "", fetchdef);
  };

  Value clean = vmap({{"values", Value(CANARY_VALUE)}});
  if (cleanopts.is_map()) {
    for (const auto& kv : *cleanopts.as_map()) map_put(clean, kv.first, kv.second);
  }

  Value opts = vmap({
    {"apikey", Value(CANARY_APIKEY)},
    {"secret", Value(CANARY_SECRET)},
    {"headers", vmap({{"X-Custom-Token", Value(CANARY_HEADER)}})},
    {"clean", clean},
    {"feature", feature},
    {"system", vmap({{"fetch", Value(fetch)}})},
  });
  if (auth.is_map()) map_put(opts, "auth", auth);
  auto sdk = construct(opts);
  sdk->getRootCtx()->utility->featureAdd(sdk->getRootCtx(), std::make_shared<CaptureFeature>(sinks));
  if (extra) sdk->getRootCtx()->utility->featureAdd(sdk->getRootCtx(), extra);
  return sdk;
}


struct Candidate {
  std::string name;
  std::vector<std::string> params;
  // The operation's data, and the match its entity then holds.
  std::function<Value(${ProjectName}SDK&, const Value&, const Value&, Value*)> run;
  std::function<std::vector<Value>(${ProjectName}SDK&, const Value&, const Value&)> stream;
};


struct Target {
  int index;
  Value match;
};


// Generated from the model: every operation the active entities declare,
// with the path parameters its points declare.
static std::vector<Candidate> candidates() {
  return {
${candidates.map((c) => candidate(ProjectName, c)).join('\n')}
  };
}


// The first operation that completes against a plain 200: with no
// arguments, else with every path parameter its points declare filled in.
static Target usableOp(const std::vector<Candidate>& cands) {
  vs::Injector fetch = [](vs::Injection&, const Value&, const std::string&, const Value&) -> Value {
    return response(200, vmap({{"id", Value("i1")}}), Value::undef());
  };
  Value opts = vmap({
    {"apikey", Value(CANARY_APIKEY)},
    {"system", vmap({{"fetch", Value(fetch)}})},
  });
  auto plain = construct(opts);
  for (size_t i = 0; i < cands.size(); i++) {
    Value filled = vmap();
    for (const auto& p : cands[i].params) map_put(filled, p, Value("p1"));
    for (const Value& match : {vmap(), filled}) {
      try {
        cands[i].run(*plain, Struct::clone(match), vmap(), nullptr);
        return {static_cast<int>(i), match};
      } catch (const SdkErrorPtr&) {
        continue;
      } catch (const std::exception&) {
        continue;
      }
    }
  }
  return {-1, Value::undef()};
}


static const char* NOTHING_TO_SWEEP =
  "SKIP: no operation of this SDK completes against a plain 200; nothing to sweep";


static SdkErrorPtr drive(${ProjectName}SDK& sdk, const Candidate& cand, const Target& target,
                         const Value& ctrl, std::vector<Sink>& sinks) {
  // A caller may keep the record it passed rather than read ctrl.explain.
  Value held = getp(ctrl, "explain");
  SdkErrorPtr err;
  Value out = Value::undef();
  Value match = Value::undef();
  bool got = false;
  try {
    out = cand.run(sdk, Struct::clone(target.match), ctrl, &match);
    got = true;
  } catch (const SdkErrorPtr& e) {
    err = e;
  } catch (const std::exception& e) {
    // Escaped the pipeline raw: swept as it is.
    err = std::make_shared<SdkError>("escaped", e.what(), nullptr);
  }
  if (err) addError(sinks, "error", err);
  if (got) addForms(sinks, "result", out);
  // Raw, as a caller copying the match into another query reads it.
  addForms(sinks, "match", match);
  Value explain = getp(ctrl, "explain");
  if (explain.is_map()) addForms(sinks, "explain", explain);
  if (held.is_map() && (!explain.is_map() || held.as_map() != explain.as_map())) {
    addForms(sinks, "explain:held", held);
  }
  return err;
}


struct Variant {
  std::string name;
  std::function<Value()> ctrl;
};


static std::vector<Variant> variants() {
  return {
    {"throw", []() { return vmap(); }},
    {"explain", []() { return vmap({{"explain", vmap()}}); }},
    {"nothrow", []() { return vmap({{"throw", Value(false)}, {"explain", vmap()}}); }},
  };
}


static void no_credential_leaves_the_sdk() {
  std::vector<Candidate> cands = candidates();
  Target target = usableOp(cands);
  if (0 > target.index) {
    std::cout << NOTHING_TO_SWEEP << std::endl;
    return;
  }
  const Candidate& cand = cands[target.index];

  std::vector<Sink> sinks;
  std::map<std::string, SdkErrorPtr> errors;
  std::map<std::string, Value> explains;

  for (const Scenario& scenario : scenarios()) {
    for (const Variant& variant : variants()) {
      auto sdk = makeSdk(scenario, &sinks, Value::undef());
      Value ctrl = variant.ctrl();
      SdkErrorPtr err = drive(*sdk, cand, target, ctrl, sinks);
      std::string key = scenario.name + "/" + variant.name;
      if (err) errors[key] = err;
      Value explain = getp(ctrl, "explain");
      if (explain.is_map()) explains[key] = explain;
      sinks.push_back({"sdk:string", sdk->to_string()});
    }
  }

  // A name given at run time replaces the declared one: the match leaves out
  // whichever name prepareAuth placed.
  drive(*makeSdk(scenarios()[0], &sinks, Value::undef(), nullptr, vmap({{"name", Value("zzcred")}})),
        cand, target, vmap(), sinks);

  // A credential mistyped as a map is rejected by validation, whose message
  // quotes the value it rejected.
  SdkErrorPtr rejected;
  try {
    std::make_shared<${ProjectName}SDK>(offline(vmap({
      {"apikey", vmap({{"value", Value(CANARY_APIKEY)}})},
      {"clean", vmap({{"values", Value(CANARY_VALUE)}})},
    })));
  } catch (const SdkErrorPtr& e) {
    rejected = e;
  }
  ASSERT_TRUE((bool)rejected, "a credential mistyped as a map should be rejected");
  if (rejected) addError(sinks, "rejected", rejected);

  // An exception a feature hook throws, quoting the request, skips makeError;
  // the variant throws again from PreUnexpected. Both run with explain on.
  for (bool unexpected : {false, true}) {
    auto hooked = makeSdk(scenarios()[0], &sinks, Value::undef(), std::make_shared<ThrowFeature>(unexpected));
    SdkErrorPtr hookerr = drive(*hooked, cand, target, vmap({{"explain", vmap()}}), sinks);
    ASSERT_TRUE((bool)hookerr, "the throwing hook should fail the operation");
  }

  // A feature's own error keeps its code, which is cleaned like the message:
  // returned, handed to a hook, thrown by a hook, and cleaned by cleanError.
  auto denier = makeSdk(scenarios()[0], &sinks, Value::undef(), std::make_shared<DenyFeature>(&sinks));
  SdkErrorPtr denied = drive(*denier, cand, target, vmap(), sinks);
  ASSERT_TRUE((bool)denied, "the refusing hook should fail the operation");
  auto raiser = makeSdk(scenarios()[0], &sinks, Value::undef(), std::make_shared<RaiseFeature>());
  SdkErrorPtr raised = drive(*raiser, cand, target, vmap(), sinks);
  ASSERT_TRUE((bool)raised, "the raising hook should fail the operation");
  auto stepped = std::make_shared<SdkError>("stepped:" + CANARY_VALUE, "stepped", nullptr);
  util::cleanError(denier->getRootCtx(), stepped);
  addError(sinks, "stepped", stepped);

  // Consuming a stream runs inside the same catch path as the operation, and
  // the explain record the caller passed is cleaned however the stream ends.
  const std::vector<std::pair<std::string, FeaturePtr>> streams = {
    {"stream", std::make_shared<StreamThrowFeature>()},
    {"stream-ok", std::make_shared<StreamOkFeature>()},
    {"stream-plain", nullptr},
  };
  for (const auto& [name, extra] : streams) {
    auto streamed = makeSdk(scenarios()[0], &sinks, Value::undef(), extra);
    Value explain = vmap();
    Value callopts = vmap({{"ctrl", vmap({{"explain", explain}})}});
    bool streamraised = false;
    try {
      for (const Value& item : cand.stream(*streamed, Struct::clone(target.match), callopts)) (void)item;
    } catch (const SdkErrorPtr& e) {
      streamraised = true;
      addError(sinks, name, e);
    } catch (const std::exception& e) {
      streamraised = true;
      sinks.push_back({name + ":what", std::string(e.what())});
    }
    ASSERT_TRUE(("stream" == name) == streamraised, name + ": only the failing stream throws");
    ASSERT_TRUE(0 < explain.as_map()->size(), name + ": the explain record was not filled");
    addForms(sinks, name + ":explain", explain);
  }

  // A client given no clean block at all masks by the schema defaults.
  Scenario notfoundsc = scenarios()[1];
  vs::Injector barefetch = [notfoundsc](vs::Injection&, const Value& args, const std::string&,
                                        const Value&) -> Value {
    Value url = vs::getelem(args, Value(int64_t(0)));
    return notfoundsc.respond(url.is_string() ? url.as_string() : "", vs::getelem(args, Value(int64_t(1))));
  };
  auto bare = construct(vmap({
    {"apikey", Value(CANARY_APIKEY)},
    {"secret", Value(CANARY_SECRET)},
    {"headers", vmap({{"X-Custom-Token", Value(CANARY_HEADER)}})},
    {"system", vmap({{"fetch", Value(barefetch)}})},
  }));
  SdkErrorPtr barerr = drive(*bare, cand, target, vmap(), sinks);
  ASSERT_TRUE((bool)barerr, "the 404 scenario must throw without a clean block");

  // The raw path returns its failure rather than throwing it.
  Value direct = makeSdk(scenarios()[3], &sinks, Value::undef())->direct(vmap({{"path", Value("raw")}}));
  ASSERT_TRUE(is_false(getp(direct, "ok")), "a transport failure should fail direct()");
  addForms(sinks, "direct", direct);

  std::string leaked;
  int leakcount = 0;
  for (const Sink& s : sinks) {
    std::vector<std::string> found = leaks(s.text);
    if (found.empty()) continue;
    leakcount++;
    if (!leaked.empty()) leaked += "; ";
    leaked += s.name + " [";
    for (size_t i = 0; i < found.size(); i++) leaked += (0 < i ? ", " : "") + found[i];
    leaked += "]";
  }

  std::cout << "clean: swept " << sinks.size() << " surface(s), " << leakcount << " leak(s)"
            << std::endl;

  ASSERT_EQ(leakcount, 0, "credential leaked through: " + leaked);

  // The positive half: the slot the credential travelled in is masked, and
  // an unregistered token in a response header is masked by name.
  auto nf = errors.find("notfound/throw");
  ASSERT_TRUE(errors.end() != nf, "the 404 scenario must throw");
  if (errors.end() != nf) {
    SdkErrorPtr notfound = nf->second;
    ASSERT_EQ(notfound->status, 404, "the 404 scenario reports its status");
    Value spec = notfound->spec;
    if (!AUTH_SUPPRESSED) {
      if ("query" == AUTH_WHERE) {
        ASSERT_EQ_VAL(header(getp(spec, "query"), AUTH_NAME), Value(MASK), "query credential masked");
      } else if ("cookie" == AUTH_WHERE) {
        std::string cookie = Struct::stringify(header(getp(spec, "headers"), "cookie"));
        ASSERT_TRUE(std::string::npos != cookie.find(MASK), "cookie: " + cookie);
      } else {
        std::string cred = Struct::stringify(header(getp(spec, "headers"), AUTH_NAME));
        ASSERT_TRUE(endsWith(cred, MASK), AUTH_NAME + ": " + cred);
      }
    }
    ASSERT_EQ_VAL(header(getp(spec, "headers"), "x-custom-token"), Value(MASK),
                  "custom token header masked");
  }
  if (denied) ASSERT_TRUE(denied->code == "denied:" + MASK, "refusal code: " + denied->code);
  if (raised) ASSERT_TRUE(raised->code == "raised:" + MASK, "raised code: " + raised->code);
  ASSERT_TRUE(stepped->code == "stepped:" + MASK, "stepped code: " + stepped->code);
  if (barerr) {
    ASSERT_EQ_VAL(header(getp(barerr->spec, "headers"), "x-custom-token"), Value(MASK),
                  "no clean block: custom token header masked");
  }

  auto ex = explains.find("ok/explain");
  Value result = explains.end() == ex ? Value::undef() : getp(ex->second, "result");
  ASSERT_TRUE(result.is_map(), "the explain record should carry the result");
  ASSERT_EQ_VAL(header(getp(result, "headers"), "x-session-token"), Value(MASK),
                "response token header masked");
}


static void the_sweep_can_see_a_leak() {
  std::vector<Candidate> cands = candidates();
  Target target = usableOp(cands);
  if (0 > target.index) {
    std::cout << NOTHING_TO_SWEEP << std::endl;
    return;
  }

  std::vector<Sink> sinks;
  auto sdk = makeSdk(scenarios()[1], &sinks, vmap({{"active", Value(false)}}));
  SdkErrorPtr err = drive(*sdk, cands[target.index], target, vmap(), sinks);
  ASSERT_TRUE((bool)err, "the 404 scenario must throw");
  if (!err) return;

  int leaked = 0;
  for (const Sink& s : sinks) {
    if (!leaks(s.text).empty()) leaked++;
  }
  ASSERT_TRUE(0 < leaked, "with clean off, nothing showed the canary: the sweep is blind");

  if (!AUTH_SUPPRESSED) {
    std::string text = vs::jsonify(err->spec, 0);
    ASSERT_TRUE(std::string::npos != text.find(CANARY_APIKEY) ||
                std::string::npos != text.find(util::cleanBase64(CANARY_APIKEY + ":" + CANARY_SECRET)),
                "the raw spec should carry the credential when clean is off");
  }

  // Explaining a failure must not cost it its error.
  std::vector<Sink> quiet;
  auto explainer = makeSdk(scenarios()[1], &quiet, vmap({{"active", Value(false)}}));
  SdkErrorPtr explained = drive(*explainer, cands[target.index], target,
                                vmap({{"explain", vmap()}}), quiet);
  ASSERT_TRUE(explained && explained->msg == err->msg,
              "with clean off, explain lost the error: " + (explained ? explained->msg : "<none>"));
}


// A registered value used as a property name is masked; names that mask
// alike are all kept.
static void a_registered_value_used_as_a_name_is_masked() {
  auto sdk = construct(vmap({
    {"clean", vmap({{"values", Value("ZZVAL-abc123,ZZVAL-xyz789")}})},
  }));
  Value out = util::clean(sdk->getRootCtx(), vmap({
    {"ZZVAL-abc123", Value(1)}, {"ZZVAL-xyz789", Value(2)}, {"plain", Value(3)},
  }));
  std::vector<std::string> keys;
  for (const auto& kv : *out.as_map()) keys.push_back(kv.first);
  ASSERT_TRUE((keys == std::vector<std::string>{MASK, MASK + "#1", "plain"}),
              "masked names: " + Struct::stringify(out));
}


// The generated config's own clean block is honoured, and left unchanged.
static void the_generated_configs_own_clean_block_is_honoured() {
  auto client = construct(vmap());
  UtilityPtr utility = client->getUtility();
  Value config = vmap({{"options", vmap({{"clean", vmap({
    {"keys", Value("zzsens")}, {"values", Value("CONFIG-SEEDED-1")},
  })}})}});
  CtxSpec cs;
  cs.utility = utility;
  cs.options = vmap({{"clean", vmap({{"values", Value("CALLER-SEEDED-2")}})}});
  cs.config = config;
  CtxPtr ctx = utility->makeContext(cs, nullptr);
  ctx->options = utility->makeOptions(ctx);
  ASSERT_EQ_VAL(util::clean(ctx, Value("a CONFIG-SEEDED-1 b CALLER-SEEDED-2")),
                Value("a " + MASK + " b " + MASK), "both seeded values are masked");
  Value out = util::clean(ctx, vmap({{"my_zzsens", Value("x")}, {"other", Value("y")}}));
  ASSERT_EQ_VAL(getp(out, "my_zzsens"), Value(MASK), "the config's key name is sensitive");
  ASSERT_EQ_VAL(getp(out, "other"), Value("y"), "an ordinary name is kept");
  ASSERT_EQ_VAL(Struct::getpath(config, {"options", "clean", "keys"}), Value("zzsens"),
                "the config's keys are left alone");
  ASSERT_EQ_VAL(Struct::getpath(config, {"options", "clean", "values"}), Value("CONFIG-SEEDED-1"),
                "the config's values are left alone");
}


// A feature's name is not a field name: a feature called secrets does not
// make its settings secret, though a sensitive field inside it still is. An
// entity block, of per-entity settings or seeded records keyed by entity name
// and id, is not read at all, and nor are rbac's rules, keyed by entity and
// operation names.
static void a_feature_name_is_read_as_a_name() {
  auto client = construct(vmap({
    {"apikey", Value(CANARY_APIKEY)},
    {"feature", vmap({
      {"secrets", vmap({
        {"active", Value(false)}, {"name", Value("ZZNAME-feat123")}, {"token", Value("ZZTOKEN-feat456")},
      })},
      {"rbac", vmap({
        {"active", Value(false)}, {"rules", vmap({{"zztoken.load", Value("PLAINRULE-k7j5h3g1")}})},
      })},
      {"test", vmap({
        {"active", Value(false)},
        {"entity", vmap({{"zztoken", vmap({{"ZZTOKEN01", vmap({{"note", Value("PLAINRECORD-t5r3e1w9")}})}})}})},
      })},
    })},
    {"entity", vmap({{"zztoken", vmap({{"alias", vmap({{"zzkey", Value("PLAINALIAS-m2n4b6v8")}})}})}})},
  }));
  CtxPtr ctx = client->getRootCtx();
  ASSERT_EQ_VAL(util::clean(ctx, Value("ZZNAME-feat123 ZZTOKEN-feat456")),
                Value("ZZNAME-feat123 " + MASK), "only the sensitive field is registered");
  ASSERT_EQ_VAL(util::clean(ctx, Value("record PLAINRECORD-t5r3e1w9")),
                Value("record PLAINRECORD-t5r3e1w9"), "a record seeded under an entity block is not registered");
  ASSERT_EQ_VAL(util::clean(ctx, Value("alias PLAINALIAS-m2n4b6v8")),
                Value("alias PLAINALIAS-m2n4b6v8"), "an entity's own settings are not registered");
  ASSERT_EQ_VAL(util::clean(ctx, Value("rule PLAINRULE-k7j5h3g1")),
                Value("rule PLAINRULE-k7j5h3g1"), "an rbac rule keyed by entity and operation is not registered");
}


int main() {
  T_RUN(no_credential_leaves_the_sdk);
  T_RUN(the_sweep_can_see_a_leak);
  T_RUN(a_registered_value_used_as_a_name_is_masked);
  T_RUN(the_generated_configs_own_clean_block_is_honoured);
  T_RUN(a_feature_name_is_read_as_a_name);
  return sdktest::summary("clean_test");
}
`
}


function cppstr(s: string): string {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'
}


export {
  TestClean
}
