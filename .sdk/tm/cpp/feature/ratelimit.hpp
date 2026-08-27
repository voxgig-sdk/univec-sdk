// Univec SDK — ratelimit feature (mirrors java feature/RatelimitFeature.java).
// Client-side rate limiting via a token bucket. Each request consumes a
// token; when the bucket is empty the request waits until the bucket refills
// at `rate` tokens per second (capacity `burst`, default: rate). The clock
// (`now`) and the wait (`sleep`) are injectable so accounting is testable.

#ifndef SDK_FEATURE_RATELIMIT_HPP
#define SDK_FEATURE_RATELIMIT_HPP

#include <algorithm>
#include <cmath>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class RatelimitFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  double tokens = 0;
  long long last = 0;

  // Activity tracking (mirrors the ts client._ratelimit record).
  int throttled = 0;
  int waitMs = 0;

  RatelimitFeature() : BaseFeature("ratelimit", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    if (!active) return;

    double rate = fopt::foptNum(options, "rate", 5);
    double burst = fopt::foptNum(options, "burst", rate);
    tokens = burst;
    last = fopt::foptNow(options)();

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      acquire();
      return inner(ctx2, url, fetchdef);
    };
  }

private:
  void acquire() {
    double rate = fopt::foptNum(options, "rate", 5);
    double burst = fopt::foptNum(options, "burst", rate);

    // Refill according to elapsed time.
    long long now = fopt::foptNow(options)();
    long long elapsed = now - last;
    last = now;
    tokens = std::min(burst, tokens + (elapsed / 1000.0) * rate);

    if (tokens >= 1) {
      tokens -= 1;
      return;
    }

    // Not enough tokens: wait for one to accrue, then consume it.
    double needed = 1 - tokens;
    int wait = (int) std::ceil((needed / rate) * 1000);
    track(wait);
    if (wait > 0) {
      fopt::foptSleep(options)(wait);
    }
    last = fopt::foptNow(options)();
    tokens = 0;
  }

  void track(int wait) {
    throttled++;
    waitMs += wait;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_RATELIMIT_HPP
