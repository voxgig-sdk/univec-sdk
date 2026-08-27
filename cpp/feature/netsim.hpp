// Univec SDK — netsim feature (mirrors java feature/NetsimFeature.java).
// Wraps the active transport and injects deterministic network conditions
// (latency, transient failures, rate limits, outages). Counter-driven per
// client; `failRate` uses a seeded LCG.

#ifndef SDK_FEATURE_NETSIM_HPP
#define SDK_FEATURE_NETSIM_HPP

#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class NetsimFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  long long seed = 1;

  int calls = 0;
  Value applied = vlist();

  NetsimFeature() : BaseFeature("netsim", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);

    seed = fopt::foptInt(options, "seed", 0);
    if (seed == 0) seed = 1;

    if (!active) return;

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      return simulate(ctx2, url, fetchdef, inner);
    };
  }

private:
  Value simulate(CtxPtr ctx, const std::string& url, const Value& fetchdef,
                 std::function<Value(CtxPtr, const std::string&, const Value&)> inner) {
    Value opts = options;
    calls++;
    int call = calls;

    Value appliedRec = vmap();

    if (fopt::foptBool(opts, "offline", false)) {
      sleep(pickLatency());
      map_put(appliedRec, "offline", Value(true));
      track(ctx, appliedRec);
      throw ctx->makeError("netsim_offline", "Simulated network offline (URL was: \"" + url + "\")");
    }

    if (call <= fopt::foptInt(opts, "errorTimes", 0)) {
      sleep(pickLatency());
      map_put(appliedRec, "error", Value(true));
      track(ctx, appliedRec);
      throw ctx->makeError("netsim_conn", "Simulated connection error (call " + std::to_string(call) + ")");
    }

    if (call <= fopt::foptInt(opts, "rateLimitTimes", 0)) {
      sleep(pickLatency());
      map_put(appliedRec, "rateLimited", Value(true));
      track(ctx, appliedRec);
      Value extra = vmap();
      map_put(extra, "statusText", Value("Too Many Requests"));
      Value headers = vmap();
      map_put(headers, "retry-after", Value(std::to_string(fopt::foptInt(opts, "retryAfter", 0))));
      map_put(extra, "headers", headers);
      return respond(429, Value(nullptr), extra);
    }

    int failStatus = fopt::foptInt(opts, "failStatus", 503);
    int failEvery = fopt::foptInt(opts, "failEvery", 0);
    bool failByCount = call <= fopt::foptInt(opts, "failTimes", 0);
    bool failByEvery = failEvery > 0 && call % failEvery == 0;
    double failRate = fopt::foptNum(opts, "failRate", 0);
    bool failByRate = failRate > 0 && rand01() < failRate;
    if (failByCount || failByEvery || failByRate) {
      sleep(pickLatency());
      map_put(appliedRec, "failStatus", Value(failStatus));
      track(ctx, appliedRec);
      Value extra = vmap();
      map_put(extra, "statusText", Value("Simulated Failure"));
      return respond(failStatus, Value(nullptr), extra);
    }

    int latency = pickLatency();
    map_put(appliedRec, "latency", Value(latency));
    track(ctx, appliedRec);
    sleep(latency);
    return inner(ctx, url, fetchdef);
  }

  int pickLatency() {
    Value l = getp(options, "latency");
    if (is_nullish(l)) return 0;
    if (l.is_map()) {
      int mn = fopt::foptInt(l, "min", 0);
      int mx = fopt::foptInt(l, "max", mn);
      if (mx <= mn) return mn;
      return mn + (int)(rand01() * (mx - mn));
    }
    int fixed = fopt::foptInt(options, "latency", 0);
    return fixed < 0 ? 0 : fixed;
  }

  void sleep(int ms) {
    if (ms <= 0) return;
    fopt::foptSleep(options)(ms);
  }

  // Deterministic 0..1 pseudo-random via a linear congruential generator.
  double rand01() {
    seed = (seed * 1103515245LL + 12345LL) & 0x7fffffffLL;
    return (double)seed / (double)0x7fffffffLL;
  }

  void track(CtxPtr ctx, const Value& appliedRec) {
    applied.as_list()->push_back(appliedRec);
    if (ctx->ctrl && ctx->ctrl->explain.is_map()) {
      Value rec = vmap();
      map_put(rec, "calls", Value(calls));
      map_put(rec, "applied", applied);
      map_put(ctx->ctrl->explain, "netsim", rec);
    }
  }

  Value respond(int status, const Value& data, const Value& extra) {
    Value out = vmap();
    map_put(out, "status", Value(status));
    map_put(out, "statusText", Value("OK"));
    map_put(out, "json", json_thunk(data));
    map_put(out, "body", Value("not-used"));
    map_put(out, "headers", vmap());
    if (extra.is_map()) {
      for (const auto& kv : *extra.as_map()) map_put(out, kv.first, kv.second);
    }
    return out;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_NETSIM_HPP
