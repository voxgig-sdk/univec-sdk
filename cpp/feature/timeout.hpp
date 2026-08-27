// Univec SDK — timeout feature (mirrors java feature/TimeoutFeature.java).
// Per-request timeout. Wraps the active transport and races each attempt
// against a wall-clock deadline; if the deadline wins, the request resolves
// to a `timeout` error instead of hanging. The inner transport is left to
// finish on its own (detached) thread — its result is discarded — matching
// how the ts feature lets the losing racer resolve unobserved.

#ifndef SDK_FEATURE_TIMEOUT_HPP
#define SDK_FEATURE_TIMEOUT_HPP

#include <chrono>
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

    // Run inner on a detached thread; the shared promise keeps the future's
    // shared state alive even after the loser resolves unobserved.
    auto prom = std::make_shared<std::promise<Value>>();
    std::future<Value> fut = prom->get_future();
    std::thread([ctx, url, fetchdef, inner, prom]() {
      try {
        prom->set_value(inner(ctx, url, fetchdef));
      } catch (...) {
        try {
          prom->set_exception(std::current_exception());
        } catch (...) {
        }
      }
    }).detach();

    if (fut.wait_for(std::chrono::milliseconds(deadline)) == std::future_status::timeout) {
      track(deadline);
      throw ctx->makeError("timeout",
          "Request exceeded timeout of " + std::to_string(deadline) + "ms");
    }

    return fut.get();
  }

  void track(int deadline) {
    count++;
    ms = deadline;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_TIMEOUT_HPP
