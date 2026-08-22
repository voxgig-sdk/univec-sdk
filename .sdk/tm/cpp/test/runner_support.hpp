// Univec SDK — shared test runner support (mirrors java
// test/RunnerSupport.java): env overrides, sdk-test-control.json skips, the
// ../.sdk/test/test.json loader, and the runset/match engine.

#ifndef SDK_TEST_RUNNER_SUPPORT_HPP
#define SDK_TEST_RUNNER_SUPPORT_HPP

#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#include "../core/sdk.hpp"
#include "testlib.hpp"

namespace sdk {
namespace rs {

// ---- file / env -------------------------------------------------------

inline std::string read_file(const std::string& path) {
  std::ifstream f(path);
  if (!f) return "";
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

inline std::map<std::string, std::string>& env_local() {
  static std::map<std::string, std::string> m;
  return m;
}
inline bool& env_local_loaded() { static bool b = false; return b; }

inline void load_env_local() {
  if (env_local_loaded()) return;
  env_local_loaded() = true;
  std::string data = read_file("../.env.local");
  std::istringstream iss(data);
  std::string line;
  while (std::getline(iss, line)) {
    size_t a = line.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) continue;
    line = line.substr(a);
    if (line.empty() || line[0] == '#') continue;
    size_t eq = line.find('=');
    if (eq != std::string::npos && eq > 0) {
      std::string k = line.substr(0, eq);
      std::string v = line.substr(eq + 1);
      auto trim = [](std::string& s) {
        size_t b = s.find_last_not_of(" \t\r\n");
        size_t c = s.find_first_not_of(" \t\r\n");
        if (c == std::string::npos) { s = ""; return; }
        s = s.substr(c, b - c + 1);
      };
      trim(k); trim(v);
      env_local()[k] = v;
    }
  }
}

inline std::string getenv_local(const std::string& key) {
  const char* v = std::getenv(key.c_str());
  if (v && v[0] != '\0') return std::string(v);
  auto it = env_local().find(key);
  return it == env_local().end() ? std::string("") : it->second;
}

inline Value env_override(Value m) {
  std::string live = getenv_local("PROJECTENV_TEST_LIVE");
  std::string over = getenv_local("PROJECTENV_TEST_OVERRIDE");
  if (live == "TRUE" || over == "TRUE") {
    if (m.is_map()) {
      for (const auto& k : Struct::keysof(m)) {
        std::string envval = getenv_local(k);
        if (!envval.empty()) {
          size_t a = envval.find_first_not_of(" \t");
          if (a != std::string::npos) envval = envval.substr(a);
          if (!envval.empty() && envval[0] == '{') {
            Value parsed = vs::parse_json(envval);
            if (!parsed.is_undef()) { map_put(m, k, parsed); continue; }
          }
          map_put(m, k, Value(envval));
        }
      }
    }
  }
  std::string explain = getenv_local("PROJECTENV_TEST_EXPLAIN");
  if (!explain.empty()) map_put(m, "PROJECTENV_TEST_EXPLAIN", Value(explain));
  return m;
}

// ---- test.json + control ---------------------------------------------

inline Value& cached_spec() { static Value v = Value::undef(); return v; }
inline Value load_test_spec() {
  if (cached_spec().is_undef()) {
    std::string data = read_file("../.sdk/test/test.json");
    cached_spec() = vs::parse_json(data);
  }
  return cached_spec();
}

inline Value& cached_control() { static Value v = Value::undef(); return v; }
inline Value load_test_control() {
  if (!cached_control().is_undef()) return cached_control();
  Value def = vs::parse_json(
      "{\"version\":1,\"test\":{\"skip\":{\"live\":{\"direct\":[],\"entityOp\":[]},"
      "\"unit\":{\"direct\":[],\"entityOp\":[]}}}}");
  std::string data = read_file("test/sdk-test-control.json");
  Value parsed = data.empty() ? Value::undef() : vs::parse_json(data);
  cached_control() = parsed.is_map() ? parsed : def;
  return cached_control();
}

// skipReason: returns {skip, reason}. skip=false when not skipped.
inline std::pair<bool, std::string> is_control_skipped(const std::string& kind,
                                                       const std::string& name,
                                                       const std::string& mode) {
  Value ctrl = load_test_control();
  Value test = Helpers::toMapAny(getp(ctrl, "test"));
  if (!test.is_map()) return {false, ""};
  Value skip = Helpers::toMapAny(getp(test, "skip"));
  if (!skip.is_map()) return {false, ""};
  Value modeMap = Helpers::toMapAny(getp(skip, mode));
  if (!modeMap.is_map()) return {false, ""};
  Value items = getp(modeMap, kind);
  if (!items.is_list()) return {false, ""};
  for (const auto& raw : *items.as_list()) {
    if (!raw.is_map()) continue;
    std::string reason = as_str(getp(raw, "reason"));
    if (kind == "direct" && as_str(getp(raw, "test")) == name) return {true, reason};
    if (kind == "entityOp") {
      std::string ent = as_str(getp(raw, "entity"));
      std::string op = as_str(getp(raw, "op"));
      if (name == ent + "." + op) return {true, reason};
    }
  }
  return {false, ""};
}

inline Value get_spec(const Value& spec, std::initializer_list<std::string> keys) {
  Value cur = spec;
  for (const auto& k : keys) {
    if (!cur.is_map()) return Value::undef();
    cur = getp(cur, k);
  }
  return Helpers::toMapAny(cur);
}

// ---- normalisation / matching ----------------------------------------

inline Value json_normalize(const Value& v) {
  // Roundtrip through JSON to drop function values and canonicalise numbers.
  return vs::parse_json(vs::jsonify(v, 0));
}

// canon: integer-valued numbers -> int; maps sorted; recursive. Returns a
// normalised Value used only for deep-equality.
inline Value canon(const Value& v) {
  if (v.is_double()) {
    double d = v.as_double();
    if (std::isfinite(d) && std::floor(d) == d) return Value((int64_t)d);
    return v;
  }
  if (v.is_list()) {
    Value out = vlist();
    for (const auto& e : *v.as_list()) out.as_list()->push_back(canon(e));
    return out;
  }
  if (v.is_map()) {
    std::vector<std::string> keys = Struct::keysof(v); // sorted
    Value out = vmap();
    for (const auto& k : keys) map_put(out, k, canon(getp(v, k)));
    return out;
  }
  return v;
}

inline bool canon_eq(const Value& a, const Value& b) { return canon(a) == canon(b); }

inline std::string to_lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower((unsigned char)c));
  return s;
}

inline bool match_string(const std::string& pattern, const std::string& val) {
  if (pattern.size() >= 2 && pattern.front() == '/' && pattern.back() == '/') {
    try {
      std::regex re(pattern.substr(1, pattern.size() - 2));
      return std::regex_search(val, re);
    } catch (...) { return false; }
  }
  return to_lower(val).find(to_lower(pattern)) != std::string::npos;
}

// match_deep: walk `check`; every leaf must equal/match base at that path.
inline void match_deep(const std::string& where, const Value& check, const Value& base,
                       const std::string& path) {
  if (check.is_undef()) return;
  if (check.is_map()) {
    for (const auto& kv : *check.as_map()) {
      Value bv = base.is_map() ? getp(base, kv.first) : Value::undef();
      match_deep(where, kv.second, bv, path + "." + kv.first);
    }
    return;
  }
  if (check.is_list()) {
    auto cl = check.as_list();
    for (size_t i = 0; i < cl->size(); i++) {
      Value bv = Value::undef();
      if (base.is_list() && i < base.as_list()->size()) bv = (*base.as_list())[i];
      match_deep(where, (*cl)[i], bv, path + "[" + std::to_string(i) + "]");
    }
    return;
  }
  // leaf
  if (check.is_string() && check.as_string() == "__EXISTS__") {
    sdktest::checks()++;
    if (is_nullish(base)) sdktest::record_fail(where, "match " + path + ": expected value to exist");
    return;
  }
  if (check.is_string() && check.as_string() == "__UNDEF__") {
    sdktest::checks()++;
    if (!is_nullish(base)) sdktest::record_fail(where, "match " + path + ": expected undef, got " + vs::jsonify(base, 0));
    return;
  }
  Value nc = json_normalize(check);
  Value nb = json_normalize(base);
  sdktest::checks()++;
  if (!canon_eq(nc, nb)) {
    if (check.is_string() && !check.as_string().empty() &&
        match_string(check.as_string(), Struct::stringify(base))) {
      return;
    }
    sdktest::record_fail(where, "match " + path + ": got " + vs::jsonify(nb, 0) + ", want " + vs::jsonify(nc, 0));
  }
}

// runset — drive a test.json entry set against a subject (which returns a
// Value or throws SdkErrorPtr). Records failures via testlib.
using RunSubject = std::function<Value(const Value& entry)>;

inline void runset(const std::string& label, const Value& testspec, RunSubject subject) {
  if (!testspec.is_map()) return;
  Value set = getp(testspec, "set");
  if (!set.is_list()) return;

  auto entries = set.as_list();
  for (size_t i = 0; i < entries->size(); i++) {
    const Value& entry = (*entries)[i];
    if (!entry.is_map()) continue;
    std::string where = label + "#" + std::to_string(i);

    Value result = Value::undef();
    SdkErrorPtr err;
    std::string errMsg;
    try {
      result = subject(entry);
    } catch (const SdkErrorPtr& e) {
      err = e;
      errMsg = e->getMessage();
    } catch (const std::exception& e) {
      err = std::make_shared<SdkError>("", e.what(), nullptr);
      errMsg = e.what();
    }

    Value expectedErr = getp(entry, "err");

    if (err) {
      if (!is_nullish(expectedErr)) {
        sdktest::checks()++;
        if (expectedErr.is_string() && !match_string(expectedErr.as_string(), errMsg)) {
          sdktest::record_fail(where, "error mismatch: got \"" + errMsg + "\", want contains \"" + expectedErr.as_string() + "\"");
        }
        Value matchSpec = Helpers::toMapAny(getp(entry, "match"));
        if (matchSpec.is_map()) {
          Value resultMap = vmap();
          map_put(resultMap, "in", getp(entry, "in"));
          map_put(resultMap, "out", json_normalize(result));
          Value errRec = vmap();
          map_put(errRec, "message", Value(errMsg));
          map_put(resultMap, "err", errRec);
          match_deep(where, matchSpec, resultMap, "");
        }
        continue;
      }
      sdktest::checks()++;
      sdktest::record_fail(where, "unexpected error: " + errMsg);
      continue;
    }

    if (!is_nullish(expectedErr)) {
      sdktest::checks()++;
      sdktest::record_fail(where, "expected error containing \"" + Struct::stringify(expectedErr) + "\" but got " + vs::jsonify(json_normalize(result), 0));
      continue;
    }

    bool matched = false;
    Value matchSpec = Helpers::toMapAny(getp(entry, "match"));
    if (matchSpec.is_map()) {
      Value resultMap = vmap();
      map_put(resultMap, "in", getp(entry, "in"));
      map_put(resultMap, "out", json_normalize(result));
      if (!is_nullish(getp(entry, "args"))) {
        map_put(resultMap, "args", getp(entry, "args"));
      } else if (!is_nullish(getp(entry, "in"))) {
        map_put(resultMap, "args", vlist({getp(entry, "in")}));
      }
      if (!is_nullish(getp(entry, "ctx"))) map_put(resultMap, "ctx", getp(entry, "ctx"));
      match_deep(where, matchSpec, resultMap, "");
      matched = true;
    }

    Value expectedOut = getp(entry, "out");
    if (is_nullish(expectedOut) && matched) continue;
    if (!is_nullish(expectedOut)) {
      sdktest::checks()++;
      Value nr = json_normalize(result);
      Value ne = json_normalize(expectedOut);
      if (!canon_eq(nr, ne)) {
        sdktest::record_fail(where, "output mismatch: got " + vs::jsonify(nr, 0) + ", want " + vs::jsonify(ne, 0));
      }
    }
  }
}

// ---- Context construction from a JSON ctx map ------------------------

struct EntityTestSetup {
  std::shared_ptr<UnivecSDK> client;
  Value data = Value::undef();
  Value idmap = Value::undef();
  Value env = Value::undef();
  bool explain = false;
  bool live = false;
  bool synthetic_only = false;
  long long now = 0;
};

// makeCtxFromMap — build a Context from a test-entry ctx/args map.
inline CtxPtr make_ctx_from_map(const Value& ctxmap_, std::shared_ptr<UnivecSDK> client,
                                UtilityPtr utility) {
  Value ctxmap = ctxmap_.is_map() ? ctxmap_ : vmap();

  CtxSpec cs;
  cs.client = client ? client.get() : nullptr;
  cs.utility = utility;
  Value opname = getp(ctxmap, "opname");
  if (opname.is_string()) cs.setOpname(opname.as_string());
  Value ctrl = Helpers::toMapAny(getp(ctxmap, "ctrl"));
  if (ctrl.is_map()) cs.ctrlMap = ctrl;
  Value meta = Helpers::toMapAny(getp(ctxmap, "meta"));
  if (meta.is_map()) cs.meta = meta;
  Value data = Helpers::toMapAny(getp(ctxmap, "data"));
  if (data.is_map()) cs.data = data;
  Value reqdata = Helpers::toMapAny(getp(ctxmap, "reqdata"));
  if (reqdata.is_map()) cs.reqdata = reqdata;
  Value match = Helpers::toMapAny(getp(ctxmap, "match"));
  if (match.is_map()) cs.match = match;
  Value reqmatch = Helpers::toMapAny(getp(ctxmap, "reqmatch"));
  if (reqmatch.is_map()) cs.reqmatch = reqmatch;
  Value point = Helpers::toMapAny(getp(ctxmap, "point"));
  if (point.is_map()) cs.point = point;

  CtxPtr ctx = utility->makeContext(cs, client ? client->getRootCtx() : nullptr);

  if (client && !ctx->options.is_map()) ctx->options = client->optionsMap();

  Value specMap = Helpers::toMapAny(getp(ctxmap, "spec"));
  if (specMap.is_map()) ctx->spec = std::make_shared<Spec>(specMap);

  Value resMap = Helpers::toMapAny(getp(ctxmap, "result"));
  if (resMap.is_map()) {
    ctx->result = std::make_shared<Result>(resMap);
    Value errMap = Helpers::toMapAny(getp(resMap, "err"));
    if (errMap.is_map() && getp(errMap, "message").is_string()) {
      ctx->result->err = std::make_shared<SdkError>("", getp(errMap, "message").as_string(), nullptr);
    }
  }

  Value respMap = Helpers::toMapAny(getp(ctxmap, "response"));
  if (respMap.is_map()) {
    ctx->response = std::make_shared<Response>(respMap);
    Value body = getp(respMap, "body");
    if (!is_nullish(body)) {
      Value b = body;
      ctx->response->jsonFunc = [b]() { return b; };
    }
    Value headers = Helpers::toMapAny(getp(respMap, "headers"));
    if (headers.is_map()) {
      Value lower = vmap();
      for (const auto& kv : *headers.as_map()) {
        std::string lk = kv.first;
        for (auto& c : lk) c = static_cast<char>(std::tolower((unsigned char)c));
        map_put(lower, lk, kv.second);
      }
      ctx->response->headers = lower;
    }
  }

  return ctx;
}

inline void fixctx(CtxPtr ctx, std::shared_ptr<UnivecSDK> client) {
  if (ctx && ctx->client && !ctx->options.is_map() && client) {
    ctx->options = client->optionsMap();
  }
}

// entityListToData — extract data maps from a list result (maps or entities).
inline Value entity_list_to_data(const Value& list) {
  Value out = vlist();
  if (!list.is_list()) return out;
  for (const auto& item : *list.as_list()) {
    if (item.is_map()) out.as_list()->push_back(item);
  }
  return out;
}

inline long long now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

} // namespace rs
} // namespace sdk

#endif // SDK_TEST_RUNNER_SUPPORT_HPP
