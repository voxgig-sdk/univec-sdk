// Univec SDK — timeout feature (mirrors java feature/TimeoutFeature.java).
// Per-request timeout. Wraps the active transport and races each attempt
// against a wall-clock deadline; if the deadline wins, the request resolves
// to a `timeout` error instead of hanging. The inner transport is left to
// finish on its own (detached) thread — its result is discarded — matching
// how the ts feature lets the losing racer resolve unobserved.

#ifndef SDK_FEATURE_TIMEOUT_HPP
#define SDK_FEATURE_TIMEOUT_HPP

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <exception>
#include <future>
#include <memory>
#include <string>
#include <thread>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class TimeoutFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Activity tracking (mirrors the ts client._timeout record).
  int count = 0;
  int ms = 0;

  TimeoutFeature() : BaseFeature("timeout", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    if (!active) return;

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      return withTimeout(ctx2, url, fetchdef, inner);
    };
  }

private:
  Value withTimeout(CtxPtr ctx, const std::string& url, const Value& fetchdef,
                    std::function<Value(CtxPtr, const std::string&, const Value&)> inner) {
    int deadline = fopt::foptInt(options, "ms", 30000);
    if (deadline <= 0) {
      return inner(ctx, url, fetchdef);
    }

    // The deadline runs from here, not from the wait below: a caller paused
    // between the two would otherwise find a late response complete and take
    // it. The worker notes when it finished, so a response or a failure after
    // the deadline is a timeout however late the caller looks. The shared
    // promise keeps the future's state alive after the loser resolves
    // unobserved on its detached thread.
    fopt::NowFn now = fopt::foptNow(options);
    const long long start = now();
    auto arrived = std::make_shared<std::atomic<long long>>(LLONG_MAX);
    auto prom = std::make_shared<std::promise<Value>>();
    std::future<Value> fut = prom->get_future();
    std::thread([ctx, url, fetchdef, inner, prom, now, arrived]() {
      try {
        Value out = inner(ctx, url, fetchdef);
        arrived->store(now());
        prom->set_value(out);
      } catch (...) {
        arrived->store(now());
        try {
          prom->set_exception(std::current_exception());
        } catch (...) {
        }
      }
    }).detach();

    long long remaining = std::max(0LL, static_cast<long long>(deadline) - (now() - start));
    if (fut.wait_for(std::chrono::milliseconds(remaining)) == std::future_status::timeout) {
      throw timeout(ctx, deadline);
    }
    if (deadline < arrived->load() - start) {
      throw timeout(ctx, deadline);
    }
    return fut.get();
  }

  SdkErrorPtr timeout(CtxPtr ctx, int deadline) {
    track(deadline);
    return ctx->makeError("timeout",
        "Request exceeded timeout of " + std::to_string(deadline) + "ms");
  }

  void track(int deadline) {
    count++;
    ms = deadline;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_TIMEOUT_HPP
