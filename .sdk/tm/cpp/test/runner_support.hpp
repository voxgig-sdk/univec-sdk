// Univec SDK — shared test runner SUPPORT (mirrors java
// test/RunnerSupport.java): env overrides, sdk-test-control.json skips, the
// ../.sdk/test/test.json loader, and Context construction from a test-entry
// ctx map.
//
// SUPPORT ONLY. The runset/match ENGINE that used to live here (and the
// whole of the retired test/struct_runner.hpp) was replaced by the vendored
// @voxgig/omni runner — see test/omni_resolver.hpp, which drives it and
// calls make_ctx_from_map/fixctx below. The file KEEPS ITS NAME because the
// generated entity suites (<entity>_direct_test.cpp, <entity>_entity_test.cpp)
// include it for read_file, load_env_local, env_override,
// is_control_skipped, entity_list_to_data and now_ms.

#ifndef SDK_TEST_RUNNER_SUPPORT_HPP
#define SDK_TEST_RUNNER_SUPPORT_HPP

#include <cctype>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <map>
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

// A minimal Entity for a test-entry ctx map. Context resolves the operation
// through the Entity INTERFACE — resolveOp keys the config lookup on
// entity->getName() — and a literal {"name": "planet"} map out of the
// fixture is not one, so entname would be "" and every op lookup would miss,
// reporting point_no_points for the whole makePoint group. (java's peer is
// PrimaryUtilityTest.PlEntity, go's is plEntity. cpp keeps it here rather
// than at the call site because Context holds a RAW Entity*, so the instance
// must outlive the Context: named_entity interns one per name for the life
// of the test binary.)
class NamedEntity : public Entity {
public:
  explicit NamedEntity(std::string name) : name_(std::move(name)) {}
  std::string getName() override { return name_; }
  EntityPtr make() override { return std::make_shared<NamedEntity>(name_); }
  Value data(const Value& arg) override { return Value::undef(); }
  Value match(const Value& arg) override { return Value::undef(); }
  void markDeleted() override { deleted_ = true; }
  bool deleted() override { return deleted_; }

private:
  std::string name_;
  bool deleted_ = false;
};

inline Entity* named_entity(const std::string& name) {
  static std::map<std::string, std::shared_ptr<NamedEntity>> interned;
  auto it = interned.find(name);
  if (it == interned.end()) {
    it = interned.emplace(name, std::make_shared<NamedEntity>(name)).first;
  }
  return it->second.get();
}

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

  // An entry may carry the whole operation lookup — the API config, the SDK
  // options that gate it, and the entity it hangs off. makePoint's group is
  // built entirely out of these three (java reads the same keys in its
  // Context constructor); without them ctx.config falls back to the client's
  // BAKED-IN config and the group asserts against the wrong endpoints.
  Value configMap = Helpers::toMapAny(getp(ctxmap, "config"));
  if (configMap.is_map()) cs.config = configMap;
  Value optionsMap = Helpers::toMapAny(getp(ctxmap, "options"));
  if (optionsMap.is_map()) cs.options = optionsMap;
  Value entityMap = Helpers::toMapAny(getp(ctxmap, "entity"));
  if (entityMap.is_map()) {
    Value entname = getp(entityMap, "name");
    if (entname.is_string()) cs.entity = named_entity(entname.as_string());
  }

  // EVERY entry gets its OWN op cache. resolveOp memoises on
  // "<entity>:<opname>", and makePoint drives seven entries that all read
  // planet:list from a DIFFERENT config — inheriting the client's root opmap
  // would serve entry one's operation to all seven and the group would pass
  // while testing one case. (java gets this for free: its makeCtxFromMap
  // builds `new Context(ctxmap, null)`, so there is no base context to
  // inherit a cache from.)
  cs.opmap = std::make_shared<OpMap>();

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
