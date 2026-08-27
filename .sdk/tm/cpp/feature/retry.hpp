// Univec SDK — retry feature (mirrors java feature/RetryFeature.java).
// Retries transient failures with exponential backoff + jitter; wraps the
// active transport so one op call may make several attempts.

#ifndef SDK_FEATURE_RETRY_HPP
#define SDK_FEATURE_RETRY_HPP

#include <cmath>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class RetryFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  long long jseed = 1;

  int attempts = 0;
  Value retries = vlist();

  RetryFeature() : BaseFeature("retry", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    if (!active) return;

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      return withRetry(ctx2, url, fetchdef, inner);
    };
  }

private:
  Value withRetry(CtxPtr ctx, const std::string& url, const Value& fetchdef,
                  std::function<Value(CtxPtr, const std::string&, const Value&)> inner) {
    int max = fopt::foptInt(options, "retries", 2);
    int minDelay = fopt::foptInt(options, "minDelay", 50);
    int maxDelay = fopt::foptInt(options, "maxDelay", 2000);
    double factor = fopt::foptNum(options, "factor", 2);

    int attempt = 0;
    while (true) {
      Value res = Value::undef();
      SdkErrorPtr err;
      try {
        res = inner(ctx, url, fetchdef);
      } catch (const SdkErrorPtr& e) {
        err = e;
      }

      if (!retryable(res, err) || attempt >= max) {
        if (err) throw err;
        return res;
      }

      int wait = backoff(res, attempt, minDelay, maxDelay, factor);
      track(attempt + 1, res, err, wait);
      sleep(wait);
      attempt++;
    }
  }

  bool retryable(const Value& res, const SdkErrorPtr& err) {
    if (err) return true;
    if (is_nullish(res)) return true;
    int status = fopt::fresStatus(res);
    if (status < 0) return false;
    Value statuses = fopt::foptList(options, "statuses");
    if (!statuses.is_list()) {
      statuses = vlist({Value(408), Value(425), Value(429), Value(500), Value(502), Value(503), Value(504)});
    }
    for (const auto& s : *statuses.as_list()) {
      if (s.is_number() && static_cast<int>(s.as_int()) == status) return true;
    }
    return false;
  }

  int backoff(const Value& res, int attempt, int minDelay, int maxDelay, double factor) {
    int ra = retryAfter(res);
    if (ra >= 0) return std::min(ra, maxDelay);
    double base = minDelay * std::pow(factor, attempt);
    int jitter = 0;
    if (fopt::foptBool(options, "jitter", true) && minDelay > 0) {
      jitter = (int)(nextRand() % (unsigned long long)minDelay);
    }
    int wait = (int)base + jitter;
    return std::min(wait, maxDelay);
  }

  int retryAfter(const Value& res) {
    std::string v = fopt::fresHeader(res, "retry-after");
    if (v.empty()) return -1;
    int seconds = fopt::fparseInt(v, -1);
    if (seconds < 0) return -1;
    return seconds * 1000;
  }

  void sleep(int ms) {
    if (ms <= 0) return;
    fopt::foptSleep(options)(ms);
  }

  unsigned long long nextRand() {
    jseed = (jseed * 1103515245LL + 12345LL) & 0x7fffffffLL;
    return (unsigned long long)jseed;
  }

  void track(int attempt, const Value& res, const SdkErrorPtr& err, int wait) {
    attempts++;
    Value entry = vmap();
    map_put(entry, "attempt", Value(attempt));
    map_put(entry, "wait", Value(wait));
    int status = fopt::fresStatus(res);
    if (status >= 0) map_put(entry, "status", Value(status));
    if (err) map_put(entry, "error", Value(err->getMessage()));
    retries.as_list()->push_back(entry);
  }
};

} // namespace sdk

#endif // SDK_FEATURE_RETRY_HPP
