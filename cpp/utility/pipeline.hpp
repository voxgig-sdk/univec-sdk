// Univec SDK — pipeline utility builders (mirrors java utility/*.java).
//
// Every pipeline step is a free function bound onto the Utility function
// fields by register_all(). Features and tests may replace individual
// fields (notably `fetcher`) on a per-instance basis.

#ifndef SDK_UTILITY_PIPELINE_HPP
#define SDK_UTILITY_PIPELINE_HPP

#include <algorithm>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <cctype>
#include <string>
#include <vector>

#include "../core/types.hpp"

// The GENERATED option spec makeOptions validates against. A leaf header
// (it includes only core/struct.hpp), so this cannot close a cycle with
// core/config.hpp, which pulls in the feature headers.
#include "../core/schema.hpp"
#include "cookie.hpp"

// prepareAuth is GENERATED, not templated: WHERE the credential goes -
// header, query or cookie, and under what name - is a fact about THIS API
// (apidef resolves it into main.kit.info.security), and this file can only
// hold one answer. It used to hold `authorization`, so an apiKey-in-query
// API got a header it does not read. The component is
// src/cmp/cpp/PrepareAuth_cpp.ts; the emitted header defines
// `sdk::util::prepareAuth` exactly as this file used to, and register_all
// below still binds it.
//
// Included HERE, outside the namespace: the generated header opens its own
// `namespace sdk { namespace util {`.
#include "prepare_auth.hpp"

namespace sdk {
namespace util {

// ---- small string helper ---------------------------------------------

inline std::string replace_all(std::string s, const std::string& from, const std::string& to) {
  if (from.empty()) return s;
  size_t pos = 0;
  while ((pos = s.find(from, pos)) != std::string::npos) {
    s.replace(pos, from.size(), to);
    pos += to.size();
  }
  return s;
}

// ---- makeContext ------------------------------------------------------

inline CtxPtr makeContext(const CtxSpec& cs, CtxPtr basectx) {
  return std::make_shared<Context>(cs, basectx);
}

// ---- clean ------------------------------------------------------------
//
// Everything that leaves the pipeline passes through clean: the error, the
// explain record, the serialised context, and whatever a feature emits.
// Two layers: every registered secret VALUE (and its encoded forms) is
// replaced wherever it appears in a string, and every value under a
// sensitive KEY name is masked whatever it holds. Inside the pipeline data
// stays raw, so a hook can still read the header it must add to.
//
// The configuration is the derived clean block makeOptions builds
// (`options.__derived__.clean`): a plain map, so the registry list inside
// it can be replaced after construction - features register later.

constexpr int CLEAN_MAXDEPTH = 32;

inline std::string cleanBase64(const std::string& in) {
  static const char* ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((in.size() + 2) / 3) * 4);
  for (size_t i = 0; i < in.size(); i += 3) {
    unsigned int v = static_cast<unsigned int>(static_cast<unsigned char>(in[i])) << 16;
    if (i + 1 < in.size()) v |= static_cast<unsigned int>(static_cast<unsigned char>(in[i + 1])) << 8;
    if (i + 2 < in.size()) v |= static_cast<unsigned int>(static_cast<unsigned char>(in[i + 2]));
    out += ALPHABET[(v >> 18) & 0x3f];
    out += ALPHABET[(v >> 12) & 0x3f];
    out += (i + 1 < in.size()) ? ALPHABET[(v >> 6) & 0x3f] : '=';
    out += (i + 2 < in.size()) ? ALPHABET[v & 0x3f] : '=';
  }
  return out;
}

inline std::string cleanNormkey(const std::string& key) {
  std::string out;
  for (char c : key) {
    if ('-' == c || '_' == c) continue;
    out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
  }
  return out;
}

inline std::vector<std::string> cleanSplit(const Value& raw) {
  std::vector<std::string> out;
  if (raw.is_list()) {
    for (const auto& v : *raw.as_list()) {
      if (v.is_string() && !v.as_string().empty()) out.push_back(v.as_string());
    }
    return out;
  }
  std::string text = raw.is_string() ? raw.as_string() : "";
  size_t start = 0;
  while (start <= text.size()) {
    size_t comma = text.find(',', start);
    std::string tok = std::string::npos == comma ? text.substr(start)
                                                 : text.substr(start, comma - start);
    size_t a = tok.find_first_not_of(" \t\r\n");
    size_t b = tok.find_last_not_of(" \t\r\n");
    tok = std::string::npos == a ? "" : tok.substr(a, b - a + 1);
    if (!tok.empty()) out.push_back(tok);
    if (std::string::npos == comma) break;
    start = comma + 1;
  }
  return out;
}

// The spec carries numbers as strings, so every target reads it alike.
inline long long cleanCount(const Value& v, long long dflt) {
  if (v.is_number()) return 0 <= v.as_int() ? v.as_int() : dflt;
  if (!v.is_string()) return dflt;
  try {
    size_t pos = 0;
    long long n = std::stoll(v.as_string(), &pos);
    return 0 <= n ? n : dflt;
  } catch (...) {
    return dflt;
  }
}

// The derived clean block, from the clean options merged over the spec.
inline Value makeCleanConfig(const Value& cleanopts) {
  Value opts = cleanopts.is_map() ? cleanopts : vmap();
  Value keys = vlist();
  for (const auto& k : cleanSplit(getp(opts, "keys"))) {
    std::string nk = cleanNormkey(k);
    if (!nk.empty()) keys.as_list()->push_back(Value(nk));
  }
  Value mask = getp(opts, "mask");
  long long min = cleanCount(getp(opts, "min"), 4);
  Value cfg = vmap();
  map_put(cfg, "active", Value(!is_false(getp(opts, "active"))));
  map_put(cfg, "keys", keys);
  map_put(cfg, "values", vlist());
  map_put(cfg, "mask", mask.is_string() ? mask : Value("[redacted]"));
  map_put(cfg, "hint", Value(cleanCount(getp(opts, "hint"), 0)));
  map_put(cfg, "min", Value(1 > min ? 1LL : min));
  return cfg;
}

// A context without options (makeError is reached with a bare one) falls
// back to the schema defaults, so nothing leaves raw for want of a
// constructor.
inline Value cleanConfig(CtxPtr ctx) {
  Value derived = ctx ? Struct::getpath(ctx->options, {"__derived__", "clean"}) : Value::undef();
  if (derived.is_map()) return derived;
  return makeCleanConfig(getp(sharedOptspec(), "clean"));
}

// The encoded forms a value travels in: Basic and Bearer both carry base64,
// a query credential is percent-encoded, and a JSON dump escapes it.
inline std::vector<std::string> cleanForms(const std::string& value) {
  std::vector<std::string> out{value};
  auto add = [&out](const std::string& s) {
    if (!s.empty() && std::find(out.begin(), out.end(), s) == out.end()) out.push_back(s);
  };
  add(cleanBase64(value));
  add(Struct::escurl(Value(value)));
  std::string json = vs::jsonify(Value(value), 0);
  if (2 <= json.size()) add(json.substr(1, json.size() - 2));
  return out;
}

inline Value cleanValues(const Value& cfg) {
  std::shared_lock<std::shared_mutex> guard(cleanRegistryLock());
  return getp(cfg, "values");
}

inline bool cleanKnown(const Value& values, const std::string& form) {
  if (!values.is_list()) return false;
  for (const auto& v : *values.as_list()) {
    if (v.is_string() && v.as_string() == form) return true;
  }
  return false;
}

// Register a secret value. Idempotent; shorter than `min` is not a secret
// the SDK can mask without blanking ordinary text. A registration publishes
// a new list and never changes a published one.
inline void cleanAddCfg(const Value& cfg, const Value& value) {
  if (!cfg.is_map() || !value.is_string()) return;
  size_t min = static_cast<size_t>(cleanCount(getp(cfg, "min"), 4));
  const std::string& raw = value.as_string();
  if (raw.size() < min) return;
  std::vector<std::string> forms;
  for (const auto& form : cleanForms(raw)) {
    if (min <= form.size()) forms.push_back(form);
  }
  auto unknown = [&forms](const Value& values) {
    std::vector<std::string> out;
    for (const auto& form : forms) {
      if (!cleanKnown(values, form)) out.push_back(form);
    }
    return out;
  };
  if (unknown(cleanValues(cfg)).empty()) return;
  std::unique_lock<std::shared_mutex> guard(cleanRegistryLock());
  Value values = getp(cfg, "values");
  std::vector<std::string> added = unknown(values);
  if (added.empty()) return;
  Value next = vlist();
  if (values.is_list()) *next.as_list() = *values.as_list();
  auto& list = *next.as_list();
  for (const auto& form : added) list.push_back(Value(form));
  std::stable_sort(list.begin(), list.end(), [](const Value& a, const Value& b) {
    return a.as_string().size() > b.as_string().size();
  });
  map_put(cfg, "values", next);
}

inline void cleanAdd(CtxPtr ctx, const Value& value) {
  cleanAddCfg(cleanConfig(ctx), value);
}

inline std::string cleanMaskValue(const Value& cfg, const std::string& value) {
  std::string mask = as_str(getp(cfg, "mask"), "[redacted]");
  size_t hint = static_cast<size_t>(cleanCount(getp(cfg, "hint"), 0));
  if (0 < hint && value.size() > 2 * hint) return mask + value.substr(value.size() - hint);
  return mask;
}

inline std::string cleanString(const Value& cfg, const std::string& text) {
  std::string out = text;
  Value values = cleanValues(cfg);
  if (!values.is_list()) return out;
  for (const auto& v : *values.as_list()) {
    if (!v.is_string() || v.as_string().empty()) continue;
    if (std::string::npos != out.find(v.as_string())) {
      out = replace_all(out, v.as_string(), cleanMaskValue(cfg, v.as_string()));
    }
  }
  return out;
}

inline bool cleanSensitiveKey(const Value& cfg, const Value& key) {
  if (!key.is_string()) return false;
  std::string nk = cleanNormkey(key.as_string());
  Value keys = getp(cfg, "keys");
  if (!keys.is_list()) return false;
  for (const auto& k : *keys.as_list()) {
    if (k.is_string() && std::string::npos != nk.find(k.as_string())) return true;
  }
  return false;
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
inline std::string cleanName(const Value& cfg, const Value& out, const std::string& key) {
  std::string name = cleanString(cfg, key);
  if (name == key || !out.as_map()->contains(name)) return name;
  int i = 1;
  while (out.as_map()->contains(name + "#" + std::to_string(i))) i++;
  return name + "#" + std::to_string(i);
}

// A plain-data copy of what is about to leave: functions are dropped,
// cycles are cut, and no live container is shared with the copy - masking
// the copy must never mask the pipeline's own spec.
inline Value cleanSnapshot(const Value& cfg, const Value& val, const Value& key, int depth,
                           std::vector<const void*>& seen) {
  if (val.is_undef() || val.is_null()) return val;

  if (val.is_string()) {
    return Value(cleanSensitiveKey(cfg, key) ? cleanMaskValue(cfg, val.as_string())
                                             : cleanString(cfg, val.as_string()));
  }

  if (val.is_func() || val.is_sentinel()) return Value::undef();

  if (!val.is_node()) {
    return cleanSensitiveKey(cfg, key) ? getp(cfg, "mask") : val;
  }

  const void* id = val.is_list() ? static_cast<const void*>(val.as_list().get())
                                 : static_cast<const void*>(val.as_map().get());
  if (CLEAN_MAXDEPTH <= depth || std::find(seen.begin(), seen.end(), id) != seen.end()) {
    return Value("[circular]");
  }

  if (cleanSensitiveKey(cfg, key)) return getp(cfg, "mask");

  seen.push_back(id);
  Value out;
  if (val.is_list()) {
    out = vlist();
    long long i = 0;
    for (const auto& item : *val.as_list()) {
      Value v = cleanSnapshot(cfg, item, Value(i++), depth + 1, seen);
      if (!v.is_undef()) out.as_list()->push_back(v);
    }
  } else {
    out = vmap();
    for (const auto& kv : *val.as_map()) {
      Value v = cleanSnapshot(cfg, kv.second, Value(kv.first), depth + 1, seen);
      if (!v.is_undef()) map_put(out, cleanName(cfg, out, kv.first), v);
    }
  }
  seen.pop_back();
  return out;
}

inline Value cleanValue(const Value& cfg, const Value& val) {
  if (is_false(getp(cfg, "active"))) return val;
  if (val.is_string()) return Value(cleanString(cfg, val.as_string()));
  std::vector<const void*> seen;
  return cleanSnapshot(cfg, val, Value::undef(), 0, seen);
}

// Clean a value on its way out: a string is redacted; anything else comes
// back as a masked plain-data copy.
inline Value clean(CtxPtr ctx, const Value& val) {
  return cleanValue(cleanConfig(ctx), val);
}

// An SdkError is cleaned IN PLACE: it is about to be thrown, and its
// identity matters to the caller.
inline void cleanError(CtxPtr ctx, const SdkErrorPtr& err) {
  if (!err) return;
  Value cfg = cleanConfig(ctx);
  if (is_false(getp(cfg, "active"))) return;
  err->msg = cleanString(cfg, err->msg);
  err->code = cleanString(cfg, err->code);
  err->result = cleanValue(cfg, err->result);
  err->spec = cleanValue(cfg, err->spec);
}

// Every scalar under a sensitive name, at any depth and of any shape, is
// registered: a credential mistyped as a map or a number is still a
// credential, and the validation error that rejects it quotes it.
inline void cleanAddSensitiveIn(const Value& cfg, const Value& val, bool under, int depth,
                                std::vector<const void*>& seen) {
  if (CLEAN_MAXDEPTH <= depth) return;
  if (val.is_string() || val.is_number()) {
    if (under) cleanAddCfg(cfg, val.is_string() ? val : Value(Struct::stringify(val)));
    return;
  }
  if (!val.is_node()) return;
  const void* id = val.is_list() ? static_cast<const void*>(val.as_list().get())
                                 : static_cast<const void*>(val.as_map().get());
  if (std::find(seen.begin(), seen.end(), id) != seen.end()) return;
  seen.push_back(id);
  if (val.is_list()) {
    for (const auto& item : *val.as_list()) cleanAddSensitiveIn(cfg, item, under, depth + 1, seen);
  } else {
    for (const auto& kv : *val.as_map()) {
      bool sub = under || cleanSensitiveKey(cfg, Value(kv.first));
      cleanAddSensitiveIn(cfg, kv.second, sub, depth + 1, seen);
    }
  }
}

inline void cleanAddSensitiveCfg(const Value& cfg, const Value& val) {
  std::vector<const void*> seen;
  cleanAddSensitiveIn(cfg, val, false, 0, seen);
}

inline void cleanAddSensitive(CtxPtr ctx, const Value& val) {
  cleanAddSensitiveCfg(cleanConfig(ctx), val);
}

// Is this key name sensitive under the context's clean configuration?
inline bool cleanKey(CtxPtr ctx, const Value& key) {
  return cleanSensitiveKey(cleanConfig(ctx), key);
}

// The explain record is the CALLER'S map (a control map is shared, not
// copied), so the cleaned copy is written back into it in place. err is
// pruned from its result, a toValue snapshot rather than the live result.
inline void cleanExplain(CtxPtr ctx) {
  Value explain = ctx->ctrl ? ctx->ctrl->explain : Value::undef();
  if (!explain.is_map()) return;
  Value cleaned = clean(ctx, explain);
  if (cleaned.is_map() && cleaned.as_map() != explain.as_map()) {
    explain.as_map()->clear();
    for (const auto& kv : *cleaned.as_map()) map_put(explain, kv.first, kv.second);
  }
  Value rm = Helpers::toMapAny(getp(explain, "result"));
  if (rm.is_map()) map_remove(rm, "err");
}

// ---- makeError --------------------------------------------------------

// Forward declaration: makeError fires the PreUnexpected feature hook, whose
// definition appears later in this header.
inline void featureHook(CtxPtr ctx, const std::string& name);

inline Value makeError(CtxPtr ctx, SdkErrorPtr err) {
  std::string opname = (!ctx->op) ? "" : ctx->op->name;
  if (opname.empty() || opname == "_") opname = "unknown operation";

  ResultPtr result = ctx->result;
  if (!result) result = std::make_shared<Result>();
  result->ok = false;

  if (!err) err = result->err;
  if (!err) err = ctx->makeError("unknown", "unknown error");

  // The source error is cleaned too: it stays reachable through the
  // response it came from.
  cleanError(ctx, err);

  std::string errmsg = err->getMessage();
  std::string msg = "UnivecSDK: " + opname + ": " + errmsg;

  result->err = nullptr;

  SpecPtr spec = ctx->spec;

  std::string code = err->code;

  auto sdkErr = std::make_shared<SdkError>(code, msg, ctx.get());
  sdkErr->result = result->toValue();
  sdkErr->spec = spec ? spec->toValue() : Value::undef();
  sdkErr->status = result->status;
  cleanError(ctx, sdkErr);

  if (ctx->ctrl->explain.is_map()) {
    Value errRecord = vmap();
    map_put(errRecord, "code", Value(sdkErr->code));
    map_put(errRecord, "message", Value(sdkErr->msg));
    map_put(ctx->ctrl->explain, "err", errRecord);
    // A pipeline failure reaches here without passing done, so the record
    // is cleaned on this path as well.
    cleanExplain(ctx);
  }

  ctx->ctrl->err = sdkErr;

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx->ctrl->err is set so hooks can read
  // the error; features guard against double-recording when PreDone fired.
  // What a hook throws here replaces the error, and leaves cleaned too.
  SdkErrorPtr raised = sdkErr;
  try {
    featureHook(ctx, "PreUnexpected");
  } catch (const SdkErrorPtr& hookerr) {
    raised = hookerr;
  } catch (const std::exception& e) {
    raised = ctx->makeError("unexpected", e.what());
  }
  if (raised != sdkErr) {
    cleanError(ctx, raised);
    cleanExplain(ctx);
    ctx->ctrl->err = raised;
  }

  if (is_false(ctx->ctrl->throwing)) {
    return result->resdata;
  }

  throw raised;
}

// ---- done -------------------------------------------------------------

inline Value done(CtxPtr ctx) {
  cleanExplain(ctx);

  if (ctx->result && ctx->result->ok) {
    return ctx->result->resdata;
  }

  return makeError(ctx, nullptr);
}

// ---- featureAdd -------------------------------------------------------

inline void featureAdd(CtxPtr ctx, FeaturePtr f) {
  SdkClient* client = ctx->client;
  auto& features = client->features;

  Value fopts = f->addOptions();

  if (fopts.is_map()) {
    std::string before = as_str(getp(fopts, "__before__"));
    std::string after = as_str(getp(fopts, "__after__"));
    std::string replace = as_str(getp(fopts, "__replace__"));

    if (!before.empty() || !after.empty() || !replace.empty()) {
      for (size_t i = 0; i < features.size(); i++) {
        std::string name = features[i]->getName();
        if (before == name) {
          features.insert(features.begin() + i, f);
          return;
        }
        if (after == name) {
          features.insert(features.begin() + i + 1, f);
          return;
        }
        if (replace == name) {
          features[i] = f;
          return;
        }
      }
    }
  }

  features.push_back(f);
}

// ---- featureInit ------------------------------------------------------

inline void featureInit(CtxPtr ctx, FeaturePtr f) {
  std::string fname = f->getName();
  Value fopts = vmap();

  if (ctx->options.is_map()) {
    Value featureOpts = Helpers::toMapAny(getp(ctx->options, "feature"));
    if (featureOpts.is_map()) {
      Value fo = Helpers::toMapAny(getp(featureOpts, fname));
      if (fo.is_map()) fopts = fo;
    }
  }

  if (is_true(getp(fopts, "active"))) {
    f->init(ctx, fopts);
  }
}

// ---- featureHook (name -> virtual dispatch; no reflection) ------------

inline void dispatch_hook(const FeaturePtr& f, const std::string& name, const CtxPtr& ctx) {
  if (name == "PostConstruct") f->postConstruct(ctx);
  else if (name == "PostConstructEntity") f->postConstructEntity(ctx);
  else if (name == "SetData") f->setData(ctx);
  else if (name == "GetData") f->getData(ctx);
  else if (name == "GetMatch") f->getMatch(ctx);
  else if (name == "SetMatch") f->setMatch(ctx);
  else if (name == "PrePoint") f->prePoint(ctx);
  else if (name == "PreSpec") f->preSpec(ctx);
  else if (name == "PreRequest") f->preRequest(ctx);
  else if (name == "PreResponse") f->preResponse(ctx);
  else if (name == "PreResult") f->preResult(ctx);
  else if (name == "PreDone") f->preDone(ctx);
  else if (name == "PreUnexpected") f->preUnexpected(ctx);
}

inline void featureHook(CtxPtr ctx, const std::string& name) {
  SdkClient* client = ctx->client;
  if (client == nullptr) return;
  if (name.empty()) return;
  std::vector<FeaturePtr> snapshot = client->features;
  for (auto& f : snapshot) {
    dispatch_hook(f, name, ctx);
  }
}

// ---- fetcher ----------------------------------------------------------

inline Value fetcher(CtxPtr ctx, const std::string& fullurl, const Value& fetchdef) {
  if (ctx->client->mode != "live") {
    throw ctx->makeError("fetch_mode_block",
        "Request blocked by mode: \"" + ctx->client->mode + "\" (URL was: \"" + fullurl + "\")");
  }

  Value options = ctx->client->optionsMap();
  if (is_true(Struct::getpath(options, {"feature", "test", "active"}))) {
    throw ctx->makeError("fetch_test_block",
        "Request blocked as test feature is active (URL was: \"" + fullurl + "\")");
  }

  Value sysFetch = Struct::getpath(options, {"system", "fetch"});

  if (sysFetch.is_injector()) {
    vs::Injection inj(Value::undef(), Value::undef());
    Value args = vlist({Value(fullurl), fetchdef});
    return sysFetch.as_injector()(inj, args, std::string(""), Value::undef());
  }

  if (is_nullish(sysFetch)) {
    // No live HTTP transport is built into the generated C++ SDK; supply a
    // system.fetch callable for live requests.
    throw ctx->makeError("fetch_no_transport",
        "live HTTP transport not available; provide options.system.fetch");
  }

  throw ctx->makeError("fetch_invalid", "system.fetch is not a valid function");
}

// ---- makeFetchDef -----------------------------------------------------

inline bool isJsonRequest(const Value& point);

inline Value makeFetchDef(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  if (!spec) {
    throw ctx->makeError("fetchdef_no_spec", "Expected context spec property to be defined.");
  }

  if (!ctx->result) ctx->result = std::make_shared<Result>();

  spec->step = "prepare";

  std::string url = ctx->utility->makeUrl(ctx);
  spec->url = url;

  Value fetchdef = vmap();
  map_put(fetchdef, "url", Value(url));
  map_put(fetchdef, "method", Value(spec->method));
  map_put(fetchdef, "headers", spec->headers);

  // A map or a list is JSON, and so is a scalar on a point that declares a
  // JSON body. Anything else goes as given.
  if (!is_nullish(spec->body)) {
    const Value& body = spec->body;
    bool scalar = body.is_string() || body.is_number() || body.is_bool();
    if (body.is_map() || body.is_list() || (scalar && isJsonRequest(ctx->point))) {
      map_put(fetchdef, "body", Value(Struct::jsonify(body)));
    } else {
      map_put(fetchdef, "body", body);
    }
  }

  return fetchdef;
}

// ---- makeUrl ----------------------------------------------------------

inline std::string makeUrl(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  ResultPtr result = ctx->result;
  if (!spec) throw ctx->makeError("url_no_spec", "Expected context spec property to be defined.");
  if (!result) throw ctx->makeError("url_no_result", "Expected context result property to be defined.");

  Value joinParts = vlist({Value(spec->base), Value(spec->prefix), Value(spec->path), Value(spec->suffix)});
  std::string url = Struct::join(joinParts, "/", true);

  // A route the definition ends with a slash keeps it: a server such as a
  // Django REST one redirects or refuses the route without it.
  Value orig = ctx->point.is_map() ? getp(ctx->point, "orig") : Value::undef();
  if (orig.is_string() && !orig.as_string().empty() && '/' == orig.as_string().back() &&
      spec->suffix.empty() && (url.empty() || '/' != url.back())) {
    url += "/";
  }

  Value resmatch = vmap();

  for (const auto& item : Struct::items(spec->params)) {
    std::string key = as_str(pair_key(item));
    Value val = pair_val(item);
    if (!is_nullish(val)) {
      url = replace_all(url, "{" + key + "}", Struct::escurl(Value(Struct::stringify(val))));
      map_put(resmatch, key, val);
    }
  }

  // A placeholder left in the route would send the request to the wrong route.
  // The base's own placeholders are server variables, resolved with the options.
  std::string base = spec->base;
  while (!base.empty() && '/' == base.back()) base.pop_back();
  const std::string route = 0 == url.compare(0, base.size(), base) ? url.substr(base.size()) : url;
  std::string unfilled;
  for (size_t at = route.find('{'); std::string::npos != at; at = route.find('{', at + 1)) {
    size_t end = route.find_first_of("{}/", at + 1);
    if (std::string::npos != end && '}' == route[end] && end > at + 1) {
      unfilled += (unfilled.empty() ? "" : ", ") + route.substr(at, end - at + 1);
      at = end;
    }
  }
  if (!unfilled.empty()) {
    throw ctx->makeError("url_param_missing", "URL path has no value for " + unfilled + ".");
  }

  std::string qsep = "?";
  for (const auto& item : Struct::items(spec->query)) {
    std::string key = as_str(pair_key(item));
    Value val = pair_val(item);
    if (!is_nullish(val)) {
      url += qsep + Struct::escurl(Value(key)) + "=" + Struct::escurl(Value(Struct::stringify(val)));
      qsep = "&";
      // Sent with the request, never recorded as the entity's match.
      if (spec->authquery.end() == std::find(spec->authquery.begin(), spec->authquery.end(), key)) {
        map_put(resmatch, key, val);
      }
    }
  }

  result->resmatch = resmatch;
  return url;
}

// ---- makePoint --------------------------------------------------------

// The name a point gives a parameter in the call, if it renames it.
inline std::string paramAlias(const Value& point, const std::string& key) {
  if (!point.is_map()) return "";
  Value alias = Helpers::toMapAny(getp(point, "alias"));
  if (!alias.is_map()) return "";
  Value ak = getp(alias, key);
  return ak.is_string() ? ak.as_string() : "";
}

// The value the call or its entity gives a point's parameter, under its name
// or the point's alias for it.
inline Value paramValue(CtxPtr ctx, const Value& point, const std::string& key) {
  std::string akey = paramAlias(point, key);

  Value val = getp(ctx->reqmatch, key, Value(nullptr));
  if (val.is_null()) val = getp(ctx->match, key, Value(nullptr));
  if (val.is_null() && !akey.empty()) val = getp(ctx->reqmatch, akey, Value(nullptr));
  if (val.is_null()) val = getp(ctx->reqdata, key, Value(nullptr));
  if (val.is_null()) val = getp(ctx->data, key, Value(nullptr));
  if (val.is_null() && !akey.empty()) {
    val = getp(ctx->reqdata, akey, Value(nullptr));
    if (val.is_null()) val = getp(ctx->data, akey, Value(nullptr));
  }

  return val;
}

// The path parameters of a point that neither the call nor the entity gives a
// value for, looked up as param looks them up.
inline std::vector<std::string> unfilledParams(CtxPtr ctx, const Value& point) {
  std::vector<std::string> missing;
  Value parts = getp(point, "parts");
  if (!parts.is_list()) return missing;
  for (const auto& part : *parts.as_list()) {
    if (!part.is_string()) continue;
    const std::string& text = part.as_string();
    if (text.size() < 3 || '{' != text.front() ||
        text.size() - 1 != text.find_first_of("{}/", 1) || '}' != text.back()) continue;
    std::string name = text.substr(1, text.size() - 2);
    if (is_nullish(paramValue(ctx, point, name))) missing.push_back(name);
  }
  return missing;
}

inline Value makePoint(CtxPtr ctx) {
  // A PrePoint feature hook (e.g. rbac) may short-circuit by storing an
  // error; surface it before any endpoint resolution or network activity.
  if (ctx->out.pointError) {
    throw ctx->out.pointError;
  }
  if (ctx->out.has_point && ctx->out.point.is_map()) {
    ctx->point = ctx->out.point;
    return ctx->point;
  }

  OperationPtr op = ctx->op;
  Value options = ctx->options;

  Value allowOpVal = Struct::getpath(options, {"allow", "op"});
  std::string allowOp = as_str(allowOpVal);
  if (!Helpers::allowed(allowOpVal, op->name)) {
    throw ctx->makeError("point_op_allow",
        "Operation \"" + op->name + "\" not allowed by SDK option allow.op value: \"" + allowOp + "\"");
  }

  if (op->points.empty()) {
    throw ctx->makeError("point_no_points",
        "Operation \"" + op->name + "\" has no endpoint definitions.");
  }

  if (op->points.size() == 1) {
    ctx->point = op->points[0];
  } else {
    Value reqselector;
    Value selector;
    if (op->input == "data") {
      reqselector = ctx->reqdata;
      selector = ctx->data;
    } else {
      reqselector = ctx->reqmatch;
      selector = ctx->match;
    }

    Value point;
    bool matched = false;
    for (size_t i = 0; i < op->points.size(); i++) {
      Value cand = op->points[i];
      Value selectDef = Helpers::toMapAny(getp(cand, "select"));
      bool found = true;

      if (selector.is_map() && selectDef.is_map()) {
        Value exist = getp(selectDef, "exist");
        if (exist.is_list()) {
          for (const auto& ek : *exist.as_list()) {
            std::string existkey = ek.is_string() ? ek.as_string() : "";
            Value rv = getp(reqselector, existkey, Value(nullptr));
            Value sv = getp(selector, existkey, Value(nullptr));
            if (rv.is_null() && sv.is_null()) {
              found = false;
              break;
            }
          }
        }
      }

      if (found) {
        Value reqAction = getp(reqselector, "$action", Value(nullptr));
        Value selectAction = getp(selectDef, "$action", Value(nullptr));
        if (reqAction != selectAction) found = false;
      }

      if (found) {
        point = cand;
        matched = true;
        break;
      }
    }

    // select.exist can list more than the params needed to pick a point (for
    // /boards/{id} it is Trello's 17 optional query-includes), so a plain
    // {id} call matches NOTHING. Fall back to the entity's own route rather
    // than whichever point came last.
    if (!matched) {
      // A request naming an action reaches here only because that action's
      // own point failed its exist test, so it is unbuildable whatever we
      // pick. Refuse it BEFORE choosing a fallback: the guard below compares
      // the chosen point's $action and would wave the request through
      // whenever the fallback lands on the action point itself.
      Value unmatchedAction = getp(reqselector, "$action", Value(nullptr));
      if (!unmatchedAction.is_null()) {
        throw ctx->makeError("point_action_invalid",
            "Operation \"" + op->name + "\" action \"" +
            Struct::stringify(unmatchedAction) + "\" is not valid.");
      }

      // A terminal parameter marks a record route (/boards/{id}); a
      // cross-reference ends in the relationship's name (/posts/{id}/author).
      // Failing that, the shallower path wins. The same rule runs at
      // generation time, in helpers/opShape.ts — both sides must move
      // together.
      auto partsLen = [](const Value& p) -> size_t {
        Value parts = getp(p, "parts");
        return parts.is_list() ? parts.as_list()->size() : 0;
      };
      auto terminalParam = [](const Value& p) -> bool {
        Value parts = getp(p, "parts");
        if (!parts.is_list() || parts.as_list()->empty()) return false;
        const Value& last = parts.as_list()->back();
        return last.is_string() && 0 == last.as_string().rfind("{", 0);
      };

      auto ownPoint = [&](const std::vector<Value>& points) {
        Value best = points[0];
        for (const auto& cand : points) {
          bool candTerm = terminalParam(cand);
          bool bestTerm = terminalParam(best);
          if (candTerm != bestTerm) {
            if (candTerm) best = cand;
          }
          else if (partsLen(cand) < partsLen(best)) {
            best = cand;
          }
        }
        return best;
      };

      // A call without an action falls back to a point without one, as
      // generation does, and only to a route the call can fill.
      std::vector<Value> plain;
      for (const auto& cand : op->points) {
        if (getp(Helpers::toMapAny(getp(cand, "select")), "$action", Value(nullptr)).is_null()) {
          plain.push_back(cand);
        }
      }
      if (plain.empty()) {
        throw ctx->makeError("point_action_required",
            "Operation \"" + op->name +
            "\" has only action endpoints; pass $action to choose one.");
      }
      std::vector<Value> fillable;
      for (const auto& cand : plain) {
        if (unfilledParams(ctx, cand).empty()) fillable.push_back(cand);
      }

      if (fillable.empty()) {
        std::string missing;
        for (const auto& name : unfilledParams(ctx, ownPoint(plain))) {
          missing += (missing.empty() ? "" : ", ") + name;
        }
        throw ctx->makeError("point_no_match",
            "Operation \"" + op->name +
            "\" has no endpoint whose path parameters are all given (missing: " + missing + ").");
      }

      point = ownPoint(fillable);
    }

    if (reqselector.is_map()) {
      Value reqAction = getp(reqselector, "$action", Value(nullptr));
      if (!reqAction.is_null() && point.is_map()) {
        Value pointSelect = Helpers::toMapAny(getp(point, "select"));
        Value pointAction = getp(pointSelect, "$action", Value(nullptr));
        if (reqAction != pointAction) {
          throw ctx->makeError("point_action_invalid",
              "Operation \"" + op->name + "\" action \"" + Struct::stringify(reqAction) + "\" is not valid.");
        }
      }
    }

    ctx->point = point;
  }

  return ctx->point;
}

// ---- graphql ----------------------------------------------------------
//
// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this unchanged. The API-specific part — which operations
// exist and what each one's document is — is model data, computed once by
// apidef and emitted into Config.

// Content type every GraphQL-over-HTTP request uses.
inline const char* graphqlContentType() { return "application/json"; }

// Map a GraphQL error to the same error codes the HTTP path produces, so a
// caller handles auth or rate limiting identically on both transports.
// Servers put the machine-readable code in `extensions.code`; Linear-style
// APIs use `extensions.type`.
inline std::string graphqlErrorCode(const Value& gqlerr) {
  Value ext = getp(gqlerr, "extensions");

  std::string raw = as_str(getp(ext, "code"));
  if (raw.empty()) raw = as_str(getp(ext, "type"));
  for (auto& ch : raw) ch = (char)std::toupper((unsigned char)ch);

  if (raw.find("AUTH") != std::string::npos ||
      raw.find("FORBIDDEN") != std::string::npos ||
      raw.find("UNAUTHENTICATED") != std::string::npos) {
    return "request_auth";
  }
  if (raw.find("RATELIMIT") != std::string::npos ||
      raw.find("RATE_LIMIT") != std::string::npos ||
      raw.find("TOO_MANY") != std::string::npos) {
    return "request_ratelimit";
  }
  if (raw.find("BAD_USER_INPUT") != std::string::npos ||
      raw.find("VALIDATION") != std::string::npos ||
      raw.find("INVALID") != std::string::npos) {
    return "request_invalid";
  }

  return "request_graphql";
}

// Build the request body for a GraphQL point.
//
// Variables come from the op's own arguments: a named variable binds to the
// like-named argument (`from`), and the input-object variable (empty
// `from`) takes the request data as a whole — which is what makes a
// generated create/update call look exactly like its REST equivalent.
inline Value graphqlBody(CtxPtr ctx) {
  Value gql = getp(ctx->point, "graphql");
  if (!gql.is_map()) return Value::undef();

  // reqmatch/reqdata hold the caller's arguments for this operation; which
  // one depends on whether the op takes match or data input.
  Value reqsrc = ctx->reqmatch;
  Value datasrc = ctx->match;
  if (ctx->op && ctx->op->input == "data") {
    reqsrc = ctx->reqdata;
    datasrc = ctx->data;
  }
  if (!reqsrc.is_map()) reqsrc = vmap();
  if (!datasrc.is_map()) datasrc = vmap();

  Value variables = vmap();

  Value varlist = getp(gql, "vars");
  if (varlist.is_list()) {
    for (const auto& spec : *varlist.as_list()) {
      if (!spec.is_map()) continue;

      std::string name = as_str(getp(spec, "name"));
      std::string from = as_str(getp(spec, "from"));

      if (from.empty()) {
        // The input object IS the request body. Strip the action selector,
        // which is an SDK-side point discriminator, not an API field.
        Value body = vmap();
        for (const auto& item : Struct::items(reqsrc)) {
          std::string key = as_str(pair_key(item));
          if ("$action" != key) map_put(body, key, pair_val(item));
        }
        map_put(variables, name, body);
        continue;
      }

      // Only send variables the caller actually supplied: sending an
      // explicit null would clear a field on many APIs.
      Value val = getp(reqsrc, from);
      if (is_nullish(val)) val = getp(datasrc, from);
      if (!is_nullish(val)) map_put(variables, name, val);
    }
  }

  Value out = vmap();
  map_put(out, "query", getp(gql, "doc"));
  map_put(out, "variables", variables);

  return out;
}

// Inspect a decoded GraphQL response body and record a failure when the
// server reported one. Returns true when an error was recorded.
//
// Partial data (`data` alongside `errors`) is treated as failure: the REST
// surface has no partial-success concept, and silently returning half an
// object would be worse than failing.
inline bool graphqlErrors(CtxPtr ctx) {
  if (!ctx->result) return false;
  if ("graphql" != as_str(getp(ctx->point, "kind"))) return false;

  Value errors = getp(ctx->result->body, "errors");
  if (!errors.is_list()) return false;

  const auto& el = *errors.as_list();
  if (el.empty()) return false;

  Value first = el[0];
  std::string msg = as_str(getp(first, "message"));
  if (msg.empty()) msg = "graphql error";
  if (1 < el.size()) {
    msg = msg + " (+" + std::to_string(el.size() - 1) + " more)";
  }

  ctx->result->err = ctx->makeError(graphqlErrorCode(first), "graphql: " + msg);
  ctx->result->ok = false;

  return true;
}

// ---- makeSpec ---------------------------------------------------------

inline SpecPtr makeSpec(CtxPtr ctx) {
  // A PreSpec feature hook (e.g. validate) may short-circuit by storing an
  // error; surface it before the request is built, the same way makePoint
  // surfaces out.pointError.
  if (ctx->out.specError) {
    throw ctx->out.specError;
  }
  if (ctx->out.spec) {
    ctx->spec = ctx->out.spec;
    return ctx->spec;
  }

  Value point = ctx->point;
  Value options = ctx->options;
  UtilityPtr utility = ctx->utility;

  Value base = getp(options, "base");
  Value prefix = getp(options, "prefix");
  Value suffix = getp(options, "suffix");
  Value parts = getp(point, "parts");

  Value specmap = vmap();
  map_put(specmap, "base", base.is_string() ? base : Value(""));
  map_put(specmap, "prefix", prefix.is_string() ? prefix : Value(""));
  if (parts.is_list()) map_put(specmap, "parts", parts);
  map_put(specmap, "suffix", suffix.is_string() ? suffix : Value(""));
  map_put(specmap, "step", Value("start"));
  ctx->spec = std::make_shared<Spec>(specmap);

  ctx->spec->method = utility->prepareMethod(ctx);

  Value allowMethodVal = Struct::getpath(options, {"allow", "method"});
  std::string allowMethod = as_str(allowMethodVal);
  if (!Helpers::allowed(allowMethodVal, ctx->spec->method)) {
    throw ctx->makeError("spec_method_allow",
        "Method \"" + ctx->spec->method + "\" not allowed by SDK option allow.method value: \"" + allowMethod + "\"");
  }

  ctx->spec->params = utility->prepareParams(ctx);
  ctx->spec->query = utility->prepareQuery(ctx);
  ctx->spec->headers = utility->prepareHeaders(ctx);

  if ("graphql" == as_str(getp(ctx->point, "kind"))) {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepareBody is skipped deliberately
    // — it only emits a body for data-input ops, whereas every GraphQL op
    // posts one, including load/list/remove.
    ctx->spec->body = graphqlBody(ctx);
    ctx->spec->path = "";
    // prepareQuery already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so
    // leaving them would send /graphql?id=i1.
    ctx->spec->query = vmap();
    map_put(ctx->spec->headers, "content-type", Value(graphqlContentType()));
  } else {
    ctx->spec->body = utility->prepareBody(ctx);
    ctx->spec->path = utility->preparePath(ctx);
  }

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "spec", ctx->spec->toValue());
  }

  // Whatever prepareAuth sets in the query, under whichever name, is the
  // credential; a key it leaves as it was is the caller's.
  std::vector<std::pair<std::string, Value>> query;
  for (const auto& item : Struct::items(ctx->spec->query)) {
    query.emplace_back(as_str(pair_key(item)), pair_val(item));
  }

  SpecPtr spec = utility->prepareAuth(ctx);
  if (spec) {
    spec->authquery.clear();
    for (const auto& item : Struct::items(spec->query)) {
      std::string key = as_str(pair_key(item));
      auto was = std::find_if(query.begin(), query.end(),
        [&](const std::pair<std::string, Value>& kv) { return kv.first == key; });
      if (query.end() == was || !(was->second == pair_val(item))) {
        spec->authquery.push_back(key);
      }
    }
  }
  ctx->spec = spec;
  return spec;
}

// ---- makeRequest ------------------------------------------------------

inline ResponsePtr makeRequest(CtxPtr ctx) {
  if (ctx->out.request) {
    return ctx->out.request;
  }

  SpecPtr spec = ctx->spec;
  UtilityPtr utility = ctx->utility;

  auto response = std::make_shared<Response>();
  auto result = std::make_shared<Result>();
  ctx->result = result;

  if (!spec) throw ctx->makeError("request_no_spec", "Expected context spec property to be defined.");

  Value fetchdef;
  try {
    fetchdef = utility->makeFetchDef(ctx);
  } catch (const SdkErrorPtr& err) {
    response->err = err;
    ctx->response = response;
    spec->step = "postrequest";
    return response;
  }

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "fetchdef", fetchdef);
  }

  spec->step = "prerequest";

  Value url = getp(fetchdef, "url");
  Value fetched;
  SdkErrorPtr fetchErr;
  try {
    fetched = utility->fetcher(ctx, url.is_string() ? url.as_string() : "", fetchdef);
  } catch (const SdkErrorPtr& err) {
    fetchErr = err;
  }

  if (fetchErr) {
    response->err = fetchErr;
  } else if (is_nullish(fetched)) {
    Value resmap = vmap();
    ctx->response = response; // placeholder
    auto e = ctx->makeError("request_no_response", "response: undefined");
    response = std::make_shared<Response>();
    response->err = e;
  } else if (fetched.is_map()) {
    response = std::make_shared<Response>(fetched);
  } else {
    response->err = ctx->makeError("request_invalid_response", "response: invalid type");
  }

  spec->step = "postrequest";
  ctx->response = response;
  return response;
}

// ---- resultBasic ------------------------------------------------------

inline ResultPtr resultBasic(CtxPtr ctx) {
  ResponsePtr response = ctx->response;
  ResultPtr result = ctx->result;

  if (result && response) {
    result->status = response->status;
    result->statusText = response->statusText;

    if (result->status >= 400) {
      std::string msg = "request: " + std::to_string(result->status) + ": " + result->statusText;
      if (result->err) {
        std::string prevmsg = result->err->getMessage();
        result->err = ctx->makeError("request_status", prevmsg + ": " + msg);
      } else {
        result->err = ctx->makeError("request_status", msg);
      }
    } else if (response->err) {
      result->err = response->err;
    }
  }

  return result;
}

// ---- resultHeaders ----------------------------------------------------

inline ResultPtr resultHeaders(CtxPtr ctx) {
  ResponsePtr response = ctx->response;
  ResultPtr result = ctx->result;

  if (result) {
    if (response && response->headers.is_map()) {
      result->headers = response->headers;
    } else {
      result->headers = vmap();
    }
  }
  return result;
}

// ---- resultBody -------------------------------------------------------

inline ResultPtr resultBody(CtxPtr ctx) {
  ResponsePtr response = ctx->response;
  ResultPtr result = ctx->result;

  if (result) {
    if (response && response->jsonFunc && !is_nullish(response->body)) {
      result->body = response->jsonFunc();
    }
    if (response && response->unreadable) {
      Value sent = ctx->spec ? ctx->spec->headers : Value::undef();
      result->err = unreadableBody(ctx, result->status, result->headers, response->body, sent,
        result->err);
    }
  }
  return result;
}

// ---- transformResponse ------------------------------------------------

inline Value transformResponse(CtxPtr ctx) {
  ResultPtr result = ctx->result;

  if (ctx->spec) ctx->spec->step = "resform";

  if (!result || !result->ok) return Value::undef();

  Value transform = Helpers::toMapAny(getp(ctx->point, "transform"));
  if (!transform.is_map()) return Value::undef();

  Value resform = getp(transform, "res");
  if (is_nullish(resform)) return Value::undef();

  Value data = vmap();
  map_put(data, "ok", Value(result->ok));
  map_put(data, "status", Value(result->status));
  map_put(data, "statusText", Value(result->statusText));
  map_put(data, "headers", result->headers);
  map_put(data, "body", result->body);
  if (result->err) map_put(data, "err", vmap({{"message", Value(result->err->msg)}}));
  map_put(data, "resdata", result->resdata);
  map_put(data, "resmatch", result->resmatch);

  Value resdata = Struct::transform(data, resform);
  result->resdata = resdata;
  return resdata;
}

// ---- makeResponse -----------------------------------------------------

inline ResponsePtr makeResponse(CtxPtr ctx) {
  if (ctx->out.response) {
    return ctx->out.response;
  }

  UtilityPtr utility = ctx->utility;
  SpecPtr spec = ctx->spec;
  ResultPtr result = ctx->result;
  ResponsePtr response = ctx->response;

  if (!spec) throw ctx->makeError("response_no_spec", "Expected context spec property to be defined.");
  if (!response) throw ctx->makeError("response_no_response", "Expected context response property to be defined.");
  if (!result) throw ctx->makeError("response_no_result", "Expected context result property to be defined.");

  spec->step = "response";

  utility->resultBasic(ctx);
  utility->resultHeaders(ctx);
  utility->resultBody(ctx);

  // GraphQL reports failures as a top-level `errors` array under HTTP 200,
  // so resultBasic's status check never sees them. Lift them here, before
  // the response transform tries to unwrap data that is not there.
  graphqlErrors(ctx);

  utility->transformResponse(ctx);

  if (!result->err) result->ok = true;

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "result", result->toValue());
  }

  return response;
}

// ---- makeResult -------------------------------------------------------

inline ResultPtr makeResult(CtxPtr ctx) {
  if (ctx->out.result) {
    return ctx->out.result;
  }

  UtilityPtr utility = ctx->utility;
  OperationPtr op = ctx->op;
  Entity* entity = ctx->entity;
  SpecPtr spec = ctx->spec;
  ResultPtr result = ctx->result;

  if (!spec) throw ctx->makeError("result_no_spec", "Expected context spec property to be defined.");
  if (!result) throw ctx->makeError("result_no_result", "Expected context result property to be defined.");

  spec->step = "result";

  utility->transformResponse(ctx);

  if (op->name == "list") {
    Value resdata = result->resdata;
    result->resdata = vlist();

    if (resdata.is_list() && !resdata.as_list()->empty() && entity != nullptr) {
      // The java donor wraps each item into an Entity object; C++ Value
      // cannot hold entity instances, so the list result carries the item
      // data maps (entityListToData treats a map item as its own data).
      // Entities are still constructed + data()-loaded so hooks fire and
      // per-item side effects match the donor.
      Value entities = vlist();
      for (const auto& entry : *resdata.as_list()) {
        EntityPtr ent = entity->make();
        if (entry.is_map()) ent->data(entry);
        entities.as_list()->push_back(entry);
        (void)ent;
      }
      result->resdata = entities;
    }
  }

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "result", result->toValue());
  }

  return result;
}

// ---- prepareMethod ----------------------------------------------------

inline std::string prepareMethod(CtxPtr ctx) {
  const std::string& opname = ctx->op->name;

  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  Value pm = getp(ctx->point, "method");
  if (pm.is_string()) {
    std::string m = as_str(pm);
    if (!m.empty()) {
      for (auto& c : m) c = (char)std::toupper((unsigned char)c);
      return m;
    }
  }

  if (opname == "create") return "POST";
  if (opname == "update") return "PUT";
  if (opname == "load") return "GET";
  if (opname == "list") return "GET";
  if (opname == "remove") return "DELETE";
  if (opname == "patch") return "PATCH";

  // An op the API does not define resolves NO method — ts answers undefined
  // here (`methodMap[key]`), and "" is C++'s spelling of the same "no
  // value", as it is go's. The stray "GET" that used to sit here was hidden
  // by the retired silent-pass engine; the shared corpus pins it now
  // (primary.prepareMethod, opname "bad" -> no output).
  return "";
}

// ---- prepareBody ------------------------------------------------------

// ---- media ------------------------------------------------------------

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.

// The data key holding a raw request body. Like `$action`, it can never be a
// declared argument name.
inline const char* rawBodyKey() { return "$body"; }

inline std::string mediaLower(std::string s) {
  for (auto& ch : s) ch = (char)std::tolower((unsigned char)ch);
  return s;
}

inline bool isJsonMedia(const Value& v) {
  if (!v.is_string()) return false;
  std::string m = v.as_string().substr(0, v.as_string().find(';'));
  size_t b = m.find_first_not_of(" \t");
  size_t e = m.find_last_not_of(" \t");
  m = std::string::npos == b ? "" : mediaLower(m.substr(b, e - b + 1));
  return m == "application/json" || m == "text/json" ||
    (m.size() >= 5 && 0 == m.compare(m.size() - 5, 5, "+json"));
}

// The declared JSON type alone, else every declared type in the model's
// order; empty when no success response declares a body.
inline std::string acceptOf(const Value& point) {
  Value res = getp(point, "response");
  Value media = getp(res, "media");
  if (!media.is_string() || media.as_string().empty()) return "";
  Value kind = getp(res, "kind");
  if (kind.is_string() && kind.as_string() == "json") return media.as_string();
  std::string out = media.as_string();
  Value alts = getp(res, "alternatives");
  if (alts.is_list()) {
    for (const auto& alt : *alts.as_list()) {
      Value m = getp(alt, "media");
      if (m.is_string() && !m.as_string().empty()) out += ", " + m.as_string();
    }
  }
  return out;
}

inline bool isRawRequest(const Value& point) {
  Value kind = getp(getp(point, "body"), "kind");
  return kind.is_string() && kind.as_string() == "raw";
}

inline bool isJsonRequest(const Value& point) {
  Value kind = getp(getp(point, "body"), "kind");
  return kind.is_string() && kind.as_string() == "json";
}

inline bool hasMediaHeader(const Value& headers, const std::string& name) {
  for (const auto& item : Struct::items(headers)) {
    if (mediaLower(as_str(pair_key(item))) == name) return true;
  }
  return false;
}

// A caller's accept wins. A declared request type replaces each JSON
// content-type, the SDK default, and leaves any other the caller set.
inline Value mediaHeaders(const Value& point, Value headers) {
  std::string accept = acceptOf(point);
  if (!accept.empty() && !hasMediaHeader(headers, "accept")) {
    map_put(headers, "accept", Value(accept));
  }

  Value body = getp(point, "body");
  Value kind = getp(body, "kind");
  Value media = getp(body, "media");
  if (kind.is_string() && (kind.as_string() == "raw" || kind.as_string() == "json") &&
      media.is_string() && !media.as_string().empty()) {
    for (const auto& item : Struct::items(headers)) {
      std::string key = as_str(pair_key(item));
      if (mediaLower(key) == "content-type" && isJsonMedia(getp(headers, key))) {
        headers.as_map()->erase(key);
      }
    }
    if (!hasMediaHeader(headers, "content-type")) map_put(headers, "content-type", media);
  }
  return headers;
}

// A string Value holds any bytes, and they are sent as they are.
inline Value rawBody(const Value& reqdata) { return getp(reqdata, rawBodyKey()); }

inline Value prepareBody(CtxPtr ctx) {
  if (ctx->op->input == "data") {
    if (isRawRequest(ctx->point)) return rawBody(ctx->reqdata);
    return ctx->utility->transformRequest(ctx);
  }
  return Value::undef();
}

// ---- callArgs ---------------------------------------------------------

// One argument a point declares, with the name it travels under and the
// value the call passes for it.
struct CallArg {
  std::string name;
  std::string wire;
  Value val;
};

// The arguments a point declares in one location, query or header, each with
// the name it travels under and the value this call passes in its match or
// else its data. Unlike a path parameter, the entity's stored match and data
// never supply one.
inline std::vector<CallArg> callArgs(CtxPtr ctx, const std::string& kind) {
  std::vector<CallArg> out;
  Value defs = ctx->point.is_map() ? getp(getp(ctx->point, "args"), kind) : Value::undef();
  if (!defs.is_list()) return out;
  for (const auto& ad : *defs.as_list()) {
    Value name = getp(ad, "name");
    if (!name.is_string() || name.as_string().empty()) continue;
    Value orig = getp(ad, "orig");
    std::string wire = orig.is_string() && !orig.as_string().empty() ?
      orig.as_string() : name.as_string();
    Value val = getp(ctx->reqmatch, name.as_string(), Value(nullptr));
    if (is_nullish(val)) val = getp(ctx->reqdata, name.as_string(), Value(nullptr));
    out.push_back({name.as_string(), wire, val});
  }
  return out;
}

// ---- prepareHeaders ---------------------------------------------------

// Strips the blanks around a cookie piece.
inline std::string trimBlank(const std::string& s) {
  size_t from = s.find_first_not_of(" \t");
  if (std::string::npos == from) return "";
  return s.substr(from, s.find_last_not_of(" \t") - from + 1);
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
inline std::string cookiePair(const std::string& wire, const Value& val) {
  auto esc = [](const Value& v) { return Struct::escurl(Value(Struct::stringify(v))); };
  std::vector<std::string> pairs;
  if (val.is_list()) {
    for (const auto& item : *val.as_list()) pairs.push_back(wire + "=" + esc(item));
  } else if (val.is_map()) {
    for (const auto& item : Struct::items(val)) {
      pairs.push_back(Struct::escurl(pair_key(item)) + "=" + esc(pair_val(item)));
    }
  } else {
    pairs.push_back(wire + "=" + esc(val));
  }
  std::string joined;
  for (size_t i = 0; i < pairs.size(); i++) joined += (0 < i ? "; " : "") + pairs[i];
  return joined;
}

inline Value prepareHeaders(CtxPtr ctx) {
  Value options = ctx->client->optionsMap();
  Value headers = getp(options, "headers");
  Value out = is_nullish(headers) ? vmap() : Helpers::toMapAny(Struct::clone(headers));
  if (!out.is_map()) out = vmap();
  out = mediaHeaders(ctx->point, out);

  // A header argument replaces a default of the same name, whatever its case.
  auto lower = [](std::string s) {
    for (auto& ch : s) ch = (char)std::tolower((unsigned char)ch);
    return s;
  };
  for (const auto& arg : callArgs(ctx, "header")) {
    if (is_nullish(arg.val)) continue;
    std::string wire = lower(arg.wire);
    for (const auto& item : Struct::items(out)) {
      std::string key = as_str(pair_key(item));
      if (lower(key) == wire) out.as_map()->erase(key);
    }
    map_put(out, wire, Value(Struct::stringify(arg.val)));
  }

  // A cookie argument travels in the cookie header, form serialized and
  // percent-encoded, replacing a cookie of the same name among those the
  // caller's headers already send.
  std::vector<CallArg> sent;
  for (const auto& arg : callArgs(ctx, "cookie")) {
    if (!is_nullish(arg.val)) sent.push_back(arg);
  }
  if (!sent.empty()) {
    std::vector<std::string> names;
    for (const auto& arg : sent) {
      if (arg.val.is_map()) {
        for (const auto& item : Struct::items(arg.val)) names.push_back(Struct::escurl(pair_key(item)));
      } else {
        names.push_back(arg.wire);
      }
    }
    std::vector<std::string> kept;
    for (const auto& item : Struct::items(out)) {
      std::string key = as_str(pair_key(item));
      if (lower(key) != "cookie") continue;
      Value given = getp(out, key);
      if (given.is_string()) {
        for (const auto& cookie : cookieKeep(given.as_string(), names)) kept.push_back(cookie);
      }
      out.as_map()->erase(key);
    }
    for (const auto& arg : sent) {
      std::string pair = cookiePair(arg.wire, arg.val);
      if (!pair.empty()) kept.push_back(pair);
    }
    if (!kept.empty()) {
      std::string joined;
      for (size_t i = 0; i < kept.size(); i++) joined += (0 < i ? "; " : "") + kept[i];
      map_put(out, "cookie", Value(joined));
    }
  }
  return out;
}

// ---- param ------------------------------------------------------------

inline Value param(CtxPtr ctx, const Value& paramdef) {
  int pt = Struct::typify(paramdef);

  std::string key;
  if (0 < (Struct::T_string & pt)) {
    key = paramdef.is_string() ? paramdef.as_string() : "";
  } else {
    Value k = getp(paramdef, "name");
    key = k.is_string() ? k.as_string() : "";
  }

  std::string akey = paramAlias(ctx->point, key);
  if (ctx->spec && !akey.empty() &&
      getp(ctx->reqmatch, key, Value(nullptr)).is_null() &&
      getp(ctx->match, key, Value(nullptr)).is_null()) {
    map_put(ctx->spec->alias, akey, Value(key));
  }

  return paramValue(ctx, ctx->point, key);
}

// ---- prepareParams ----------------------------------------------------

inline Value prepareParams(CtxPtr ctx) {
  UtilityPtr utility = ctx->utility;
  Value point = ctx->point;

  Value params = Value::undef();
  Value argsMap = Helpers::toMapAny(getp(point, "args"));
  if (argsMap.is_map()) {
    Value p = getp(argsMap, "params");
    if (p.is_list()) params = p;
  }
  if (!params.is_list()) params = vlist();

  Value out = vmap();
  for (const auto& pd : *params.as_list()) {
    Value val = utility->param(ctx, pd);
    if (!is_nullish(val)) {
      Value pdm = Helpers::toMapAny(pd);
      if (pdm.is_map()) {
        Value name = getp(pdm, "name");
        if (name.is_string() && !name.as_string().empty()) {
          map_put(out, name.as_string(), val);
        }
      }
    }
  }
  return out;
}

// ---- prepareQuery -----------------------------------------------------

inline Value prepareQuery(CtxPtr ctx) {
  Value point = ctx->point;
  Value reqmatch = ctx->reqmatch;
  if (!reqmatch.is_map()) reqmatch = vmap();

  Value params = Value::undef();
  if (point.is_map()) {
    Value p = getp(point, "params");
    if (p.is_list()) params = p;
  }
  if (!params.is_list()) params = vlist();

  auto contains_str = [&](const Value& list, const std::string& s) {
    for (const auto& v : *list.as_list()) {
      if (v.is_string() && v.as_string() == s) return true;
    }
    return false;
  };

  // A path parameter travels in the path. The generated config lists them as
  // args.params, which prepareParams reads; params is the older list of names.
  Value aparams = point.is_map() ? getp(getp(point, "args"), "params") : Value::undef();
  Value aheader = point.is_map() ? getp(getp(point, "args"), "header") : Value::undef();
  Value acookie = point.is_map() ? getp(getp(point, "args"), "cookie") : Value::undef();
  auto named = [&](const Value& defs, const std::string& s) {
    if (!defs.is_list()) return false;
    for (const auto& pd : *defs.as_list()) {
      Value name = getp(pd, "name");
      if (name.is_string() && name.as_string() == s) return true;
    }
    return false;
  };

  // A header or cookie parameter travels in the headers, which prepareHeaders
  // fills, unless a query parameter shares its name: then both are sent.
  Value aquery = point.is_map() ? getp(getp(point, "args"), "query") : Value::undef();
  auto elsewhere = [&](const std::string& s) { return (named(aheader, s) || named(acookie, s)) && !named(aquery, s); };

  // A query parameter travels under the name the definition gives it, its
  // orig, which the model may have renamed for the caller.
  auto wire_name = [&](const std::string& s) {
    if (aquery.is_list()) {
      for (const auto& qd : *aquery.as_list()) {
        Value name = getp(qd, "name");
        Value orig = getp(qd, "orig");
        if (name.is_string() && orig.is_string() && name.as_string() == s &&
            !orig.as_string().empty()) {
          return orig.as_string();
        }
      }
    }
    return s;
  };

  Value out = vmap();
  for (const auto& item : Struct::items(reqmatch)) {
    std::string key = as_str(pair_key(item));
    Value val = pair_val(item);
    if (!is_nullish(val) && "$action" != key && !contains_str(params, key) &&
        !named(aparams, key) && !elsewhere(key)) {
      map_put(out, wire_name(key), val);
    }
  }

  // A create or update passes its query arguments in its data.
  for (const auto& arg : callArgs(ctx, "query")) {
    if (!is_nullish(arg.val) && !contains_str(params, arg.name) &&
        !named(aparams, arg.name) && !elsewhere(arg.name)) {
      map_put(out, arg.wire, arg.val);
    }
  }
  return out;
}

// ---- preparePath ------------------------------------------------------

inline std::string preparePath(CtxPtr ctx) {
  Value parts = getp(ctx->point, "parts");
  if (!parts.is_list()) parts = vlist();
  return Struct::join(parts, "/", true);
}

// ---- prepareAuth ------------------------------------------------------
//
// GENERATED into utility/prepare_auth.hpp, included at the top of this file
// (see the note there). `util::prepareAuth` keeps its name, its signature
// and its binding in register_all below; only the three-way choice of WHERE
// the credential goes moved out, because a template cannot make it.

// ---- transformRequest -------------------------------------------------

inline Value omitKeys(const Value& reqdata, const std::vector<std::string>& names) {
  bool has = false;
  for (const auto& name : names) has = has || map_contains(reqdata, name);
  if (!has) return reqdata;
  Value body = vmap();
  for (const auto& item : Struct::items(reqdata)) {
    std::string key = as_str(pair_key(item));
    if (std::find(names.begin(), names.end(), key) == names.end()) map_put(body, key, pair_val(item));
  }
  return body;
}

// `$action` selects the point (see makePoint); it is never an API field, so
// the body is a copy without it. The caller's map is left untouched.
inline Value stripAction(const Value& reqdata) { return omitKeys(reqdata, {"$action"}); }

inline bool fieldArg(CtxPtr ctx, const std::string& name) {
  if (!ctx->point.is_map()) return false;
  for (const char* kind : {"header", "cookie", "query"}) {
    Value defs = getp(getp(ctx->point, "args"), kind);
    if (!defs.is_list()) continue;
    for (const auto& ad : *defs.as_list()) {
      Value n = getp(ad, "name");
      Value f = getp(ad, "field");
      if (n.is_string() && n.as_string() == name && f.is_bool() && f.as_bool()) return true;
    }
  }
  return false;
}

// A header, cookie or query argument travels where prepareHeaders or
// prepareQuery sends it, so the body is built from the request data without
// it, unless the point marks it as a field the body keeps.
inline std::vector<std::string> routedArgNames(CtxPtr ctx) {
  std::vector<std::string> names;
  for (const char* kind : {"header", "cookie", "query"}) {
    for (const auto& arg : callArgs(ctx, kind)) {
      if (!fieldArg(ctx, arg.name)) names.push_back(arg.name);
    }
  }
  return names;
}

inline Value transformRequest(CtxPtr ctx) {
  if (ctx->spec) ctx->spec->step = "reqform";

  Value reqdata = omitKeys(ctx->reqdata, routedArgNames(ctx));

  Value transform = Helpers::toMapAny(getp(ctx->point, "transform"));
  if (!transform.is_map()) return stripAction(reqdata);

  Value reqform = getp(transform, "req");
  if (is_nullish(reqform)) return stripAction(reqdata);

  Value data = vmap();
  map_put(data, "reqdata", reqdata);
  return stripAction(Struct::transform(data, reqform));
}

// ---- makeOptions ------------------------------------------------------

inline Value optsPlain(const Value& settings, const std::string& name) {
  if (!settings.is_map()) return settings;
  Value out = vmap();
  for (const auto& kv : *settings.as_map()) {
    if ("entity" != kv.first && !("rbac" == name && "rules" == kv.first)) {
      map_put(out, kv.first, kv.second);
    }
  }
  return out;
}

// The options to scan for secrets. The feature map is keyed by feature
// names, not field names, so it is scanned as a list: `secrets` must not
// make every setting of that feature a secret. Entity blocks hold entity
// settings and seeded records, never a credential, so none is scanned, and
// nor are rbac's rules, keyed by entity and operation names. The raw scan
// still sees the feature list form, whose entries each carry `name`.
inline Value optsWithout(const Value& opts, std::initializer_list<const char*> keys) {
  Value out = vmap();
  if (!opts.is_map()) return out;
  for (const auto& kv : *opts.as_map()) {
    bool skip = "entity" == kv.first;
    for (const char* k : keys) skip = skip || kv.first == k;
    if (skip) continue;
    if ("feature" == kv.first && (kv.second.is_map() || kv.second.is_list())) {
      Value list = vlist();
      if (kv.second.is_map()) {
        for (const auto& f : *kv.second.as_map()) list.as_list()->push_back(optsPlain(f.second, f.first));
      } else {
        for (const auto& f : *kv.second.as_list()) {
          Value name = f.is_map() ? getp(f, "name") : Value::undef();
          list.as_list()->push_back(optsPlain(f, name.is_string() ? name.as_string() : ""));
        }
      }
      map_put(out, kv.first, list);
    } else if ("test" == kv.first) {
      map_put(out, kv.first, optsPlain(kv.second, ""));
    } else {
      map_put(out, kv.first, kv.second);
    }
  }
  return out;
}

// A templated base URL takes each {name} from options.server. An empty value
// cannot make a working URL, so it fails construction, except in test mode,
// where it becomes test-<name>.
inline std::string resolveServerBase(const std::string& base, const Value& opts,
                                     const Value& config, CtxPtr ctx) {
  bool testmode = is_true(Struct::getpath(opts, {"test", "active"}))
    || is_true(Struct::getpath(opts, {"feature", "test", "active"}));
  Value server = Helpers::toMapAny(getp(opts, "server"));
  Value nameV = Struct::getpath(config, {"main", "name"});
  std::string sdkname = nameV.is_string() && !nameV.as_string().empty()
    ? nameV.as_string() : "SDK";
  auto namechar = [](char c) {
    return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') || '_' == c;
  };

  std::string out;
  size_t i = 0;
  while (i < base.size()) {
    size_t j = i + 1;
    if ('{' == base[i]) {
      while (j < base.size() && namechar(base[j])) j++;
    }
    // A placeholder only when it closes and the name is [A-Za-z0-9_]+.
    if ('{' != base[i] || j == i + 1 || j >= base.size() || '}' != base[j]) {
      out += base[i];
      i++;
      continue;
    }
    std::string name = base.substr(i + 1, j - i - 1);
    Value val = server.is_map() ? getp(server, name) : Value::undef();
    if (val.is_string() && !val.as_string().empty()) {
      out += val.as_string();
    } else if (testmode) {
      out += "test-" + name;
    } else {
      throw std::make_shared<SdkError>("server_var_required",
          sdkname + ": the server variable '" + name + "' is required: the API base URL is '" +
          base + "' - pass {\"server\", vmap({{\"" + name + "\", Value(\"...\")}})} in the SDK options",
          ctx.get());
    }
    i = j + 1;
  }
  return out;
}

inline Value makeOptions(CtxPtr ctx) {
  Value options = ctx->options;
  if (!options.is_map()) options = vmap();

  // Merge custom utility overrides onto the utility object BEFORE clone —
  // struct clone preserves function Values, but we read from the original
  // to match the donors and keep the (function) values intact.
  Value customUtils = Helpers::toMapAny(getp(options, "utility"));
  if (customUtils.is_map() && ctx->utility) {
    for (const auto& item : Struct::items(customUtils)) {
      map_put(ctx->utility->custom, as_str(pair_key(item)), pair_val(item));
    }
  }

  // `auth: null` is the documented way to disable auth outright, and
  // prepareAuth honours it before it ever reads the apikey. It cannot survive
  // validate: this port follows the Group A rule, so a stored null reads as
  // "no value" and the optspec's `auth` default fires instead - transmitting
  // the credential the caller withheld. Withhold the key for validate, then
  // put the null back. Same fix as ts/js/go makeOptions.
  //
  // mapget rather than getp: getp applies Group A and collapses a stored null
  // to undef, so it cannot tell an ABSENT auth from a suppressed one. And the
  // test is is_null, NOT is_nullish - a present-but-UNDEF auth is a missing
  // value, which the ts/js reference lets the optspec default fill in. Only an
  // explicit null is a suppression.
  bool authSuppressed = mapget(options, "auth").is_null();

  Value opts = Struct::clone(options);

  if (authSuppressed) {
    map_remove(opts, "auth");
  }

  Value config = ctx->config;
  if (!config.is_map()) config = vmap();
  Value cfgopts = Helpers::toMapAny(getp(config, "options"));
  if (!cfgopts.is_map()) cfgopts = vmap();

  // The secret registry exists BEFORE validation, fed from the raw input, so
  // the constructor's own rejection of a mistyped credential is clean too.
  Value cleanraw = vlist({vmap()});
  for (const Value& src : {getp(sharedOptspec(), "clean"), getp(cfgopts, "clean"), getp(opts, "clean")}) {
    if (src.is_map()) cleanraw.as_list()->push_back(Struct::clone(src));
  }
  Value derivedClean = makeCleanConfig(Struct::merge(cleanraw));
  cleanAddSensitiveCfg(derivedClean, optsWithout(opts, {"clean"}));
  for (const Value& src : {cfgopts, opts}) {
    for (const auto& raw : cleanSplit(Struct::getpath(src, {"clean", "values"}))) {
      cleanAddCfg(derivedClean, Value(raw));
    }
  }

  // Feature add-order. options.feature may be an ordered list of
  // { name, active, ...opts } entries (the list position IS the order in which
  // features are added), or a { name: {opts} } map. Normalize a list to a map
  // (so merge/validate are unchanged) and remember the explicit order; a map
  // defaults to test-first so the `test` mock transport is installed as the
  // base of the transport wrapper chain.
  std::vector<std::string> featureOrder;
  {
    Value rawFeature = getp(opts, "feature");
    if (rawFeature.is_list()) {
      Value fmap = vmap();
      for (const auto& entry : *rawFeature.as_list()) {
        if (entry.is_map()) {
          Value nameV = getp(entry, "name");
          if (nameV.is_string()) {
            std::string nm = nameV.as_string();
            Value fopts = Struct::clone(entry);
            map_remove(fopts, "name");
            map_put(fmap, nm, fopts);
            featureOrder.push_back(nm);
          }
        }
      }
      map_put(opts, "feature", fmap);
    }
  }

  // THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.
  //
  // Built from the model: `main.kit.optspec` for the standard options, plus
  // one entry per feature this target carries, from that feature's own
  // `config.options` / `config.optspec`. This file used to carry its own
  // OPTSPEC_JSON() - one of twenty hand-maintained copies of a schema nothing
  // cross-checked, and it had already drifted (no `extend`, no `server`, no
  // `auth.basic`). Add an option to the model instead and every ported target
  // validates it.
  //
  // Parsed once and shared: makeOptions validates AGAINST the spec and writes
  // into the options, never into the spec.
  const Value& optspec = sharedOptspec();

  // Preserve system.fetch before merge/validate (a function Value may be
  // dropped by validate).
  Value sysFetch = Struct::getpath(opts, {"system", "fetch"});

  // CLONE the config side: `config` is a process-wide singleton (sharedConfig)
  // and merge uses its nested maps as merge TARGETS, so without this one
  // client's options (headers, server, ...) are written into the shared config
  // and inherited by every client constructed afterwards.
  Value mergeList = vlist({vmap(), Struct::clone(cfgopts), opts});
  Value merged = Struct::merge(mergeList);

  Value vopts = vmap();
  Value verrs = vlist();
  map_put(vopts, "errs", verrs);
  Value validated = Struct::validate(merged, optspec, vopts);
  if (!verrs.as_list()->empty()) {
    std::string vmsg;
    for (const auto& e : *verrs.as_list()) {
      if (!vmsg.empty()) vmsg += " | ";
      vmsg += Struct::stringify(e);
    }
    throw std::make_shared<SdkError>("options_invalid",
        cleanString(derivedClean, "UnivecSDK: invalid options: " + vmsg), ctx.get());
  }
  opts = validated;

  // Restore the suppression the optspec default would otherwise erase.
  if (authSuppressed) {
    map_put(opts, "auth", Value(nullptr));
  }

  if (!is_nullish(sysFetch)) {
    Value sys = Helpers::toMapAny(getp(opts, "system"));
    if (sys.is_map()) {
      map_put(sys, "fetch", sysFetch);
    } else {
      Value sm = vmap();
      map_put(sm, "fetch", sysFetch);
      map_put(opts, "system", sm);
    }
  }

  Value baseV = getp(opts, "base");
  if (baseV.is_string() && std::string::npos != baseV.as_string().find('{')) {
    map_put(opts, "base", Value(resolveServerBase(baseV.as_string(), opts, config, ctx)));
  }

  // Resolve the feature add-order: an explicit list order (above) wins;
  // otherwise order the map test-first, then the remaining names sorted, so
  // the outcome is deterministic and `test` is always the base transport.
  if (featureOrder.empty()) {
    Value featureMap = Helpers::toMapAny(getp(opts, "feature"));
    if (featureMap.is_map()) {
      std::vector<std::string> names;
      for (const auto& item : Struct::items(featureMap)) {
        names.push_back(as_str(pair_key(item)));
      }
      std::sort(names.begin(), names.end());
      bool hasTest = std::find(names.begin(), names.end(), "test") != names.end();
      if (hasTest) featureOrder.push_back("test");
      // Station special case, mirroring test's: its transport wrap must
      // sit immediately outside the base transport (inside retry/cache/
      // netsim), so map-form activation hoists it to just after test -
      // or first, when no test entry exists. Without this the sorted
      // default would init station last and wrap OUTSIDE the recording
      // features, turning its wire-truth events into fiction.
      bool hasStation = std::find(names.begin(), names.end(), "station") != names.end();
      if (hasStation) featureOrder.push_back("station");
      for (const auto& n : names) {
        if (n != "test" && n != "station") featureOrder.push_back(n);
      }
    }
  }
  Value orderList = vlist();
  for (const auto& n : featureOrder) orderList.as_list()->push_back(Value(n));

  Value derived = vmap();
  map_put(derived, "clean", derivedClean);
  map_put(derived, "featureorder", orderList);
  map_put(opts, "__derived__", derived);

  // Again over the merged result: the config's own defaults can carry one.
  cleanAddSensitiveCfg(derivedClean, optsWithout(opts, {"clean", "__derived__"}));

  return opts;
}

// =======================================================================
// register_all — wire the Utility function fields (mirrors java Register).
// =======================================================================

} // namespace util

inline void register_all(Utility& u) {
  u.clean = util::clean;
  u.cleanAdd = util::cleanAdd;
  u.cleanExplain = util::cleanExplain;
  u.done = util::done;
  u.makeError = util::makeError;
  u.featureAdd = util::featureAdd;
  u.featureHook = util::featureHook;
  u.featureInit = util::featureInit;
  u.fetcher = util::fetcher;
  u.makeFetchDef = util::makeFetchDef;
  u.makeContext = util::makeContext;
  u.makeOptions = util::makeOptions;
  u.makeRequest = util::makeRequest;
  u.makeResponse = util::makeResponse;
  u.makeResult = util::makeResult;
  u.makePoint = util::makePoint;
  u.makeSpec = util::makeSpec;
  u.makeUrl = util::makeUrl;
  u.param = util::param;
  u.prepareAuth = util::prepareAuth;
  u.prepareBody = util::prepareBody;
  u.prepareHeaders = util::prepareHeaders;
  u.prepareMethod = util::prepareMethod;
  u.prepareParams = util::prepareParams;
  u.preparePath = util::preparePath;
  u.prepareQuery = util::prepareQuery;
  u.resultBasic = util::resultBasic;
  u.resultBody = util::resultBody;
  u.resultHeaders = util::resultHeaders;
  u.transformRequest = util::transformRequest;
  u.transformResponse = util::transformResponse;
}

} // namespace sdk

#endif // SDK_UTILITY_PIPELINE_HPP
