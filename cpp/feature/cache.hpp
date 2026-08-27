// Univec SDK — cache feature (mirrors java feature/CacheFeature.java).
// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the
// same method+URL was fetched within `ttl` ms (default: 5000). Only
// successful (2xx) responses to cacheable methods (default: GET) are stored,
// keyed by method+URL, bounded (`max`, default 256, oldest evicted first).
// Bodies are snapshotted so both the current caller and later hits re-read
// the JSON body repeatedly.

#ifndef SDK_FEATURE_CACHE_HPP
#define SDK_FEATURE_CACHE_HPP

#include <cctype>
#include <map>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class CacheFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Activity tracking (mirrors the ts client._cache record).
  int hit = 0;
  int miss = 0;
  int bypass = 0;

  CacheFeature() : BaseFeature("cache", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    if (!active) return;

    store.clear();
    order.clear();

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      return through(ctx2, url, fetchdef, inner);
    };
  }

private:
  struct CacheSnapshot {
    int status = 0;
    std::string statusText = "";
    Value data = Value::undef();
    Value headers = vmap();
  };

  struct CacheEntry {
    long long expiry = 0;
    CacheSnapshot snapshot;
  };

  std::map<std::string, CacheEntry> store;
  std::vector<std::string> order;

  static std::string upper(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::toupper((unsigned char)c));
    return s;
  }

  Value through(CtxPtr ctx, const std::string& url, const Value& fetchdef,
                std::function<Value(CtxPtr, const std::string&, const Value&)> inner) {
    std::string method = "GET";
    Value m = getp(fetchdef, "method");
    if (m.is_string() && !m.as_string().empty()) {
      method = upper(m.as_string());
    }

    std::vector<std::string> methods = fopt::foptStrList(options, "methods");
    if (!fopt::foptList(options, "methods").is_list()) {
      methods = {"GET"};
    }
    bool cacheable = false;
    for (const auto& cm : methods) {
      if (upper(cm) == method) {
        cacheable = true;
        break;
      }
    }
    if (!cacheable) {
      return inner(ctx, url, fetchdef);
    }

    std::string key = method + " " + url;
    long long now = fopt::foptNow(options)();

    auto it = store.find(key);
    if (it != store.end() && it->second.expiry > now) {
      hit++;
      return replay(it->second.snapshot);
    }

    Value res;
    try {
      res = inner(ctx, url, fetchdef);
    } catch (const SdkErrorPtr& err) {
      bypass++;
      throw err;
    }

    if (storable(res)) {
      CacheSnapshot snap = snapshot(res);
      int ttl = fopt::foptInt(options, "ttl", 5000);
      evict();
      CacheEntry entry;
      entry.expiry = now + ttl;
      entry.snapshot = snap;
      store[key] = entry;
      order.push_back(key);
      miss++;
      return replay(snap);
    }

    bypass++;
    return res;
  }

  bool storable(const Value& res) {
    int status = fopt::fresStatus(res);
    return status >= 200 && status < 300;
  }

  CacheSnapshot snapshot(const Value& res) {
    CacheSnapshot snap;

    int status = fopt::fresStatus(res);
    if (status >= 0) snap.status = status;

    if (res.is_map()) {
      Value st = getp(res, "statusText");
      if (st.is_string()) snap.statusText = st.as_string();

      Value jf = mapget(res, "json");
      if (jf.is_injector()) {
        vs::Injection inj(Value::undef(), Value::undef());
        snap.data = jf.as_injector()(inj, Value::undef(), std::string(""), Value::undef());
      }

      Value headers = getp(res, "headers");
      if (headers.is_map()) {
        for (const auto& kv : *headers.as_map()) {
          std::string lk = kv.first;
          for (auto& c : lk) c = static_cast<char>(std::tolower((unsigned char)c));
          map_put(snap.headers, lk, kv.second);
        }
      }
    }

    return snap;
  }

  // replay builds a fresh transport-shaped response so the body stays
  // re-readable for every consumer.
  Value replay(const CacheSnapshot& snap) {
    Value out = vmap();
    map_put(out, "status", Value(snap.status));
    map_put(out, "statusText", Value(snap.statusText));
    map_put(out, "body", Value("not-used"));
    map_put(out, "json", json_thunk(snap.data));
    map_put(out, "headers", Struct::clone(snap.headers));
    return out;
  }

  // evict drops oldest entries (FIFO) until the store is under `max`.
  void evict() {
    int max = fopt::foptInt(options, "max", 256);
    while ((int) store.size() >= max && !order.empty()) {
      std::string oldest = order.front();
      order.erase(order.begin());
      store.erase(oldest);
    }
  }
};

} // namespace sdk

#endif // SDK_FEATURE_CACHE_HPP
