// Univec SDK — metrics feature (mirrors java feature/MetricsFeature.java).
// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone) or
// fails (PreUnexpected); each operation is recorded exactly once (the
// per-context start marker — java ctx.out — is kept here keyed by ctx.id).
// The clock is injectable (`now`).

#ifndef SDK_FEATURE_METRICS_HPP
#define SDK_FEATURE_METRICS_HPP

#include <map>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class MetricsFeature : public BaseFeature {
public:
  struct MetricsBucket {
    int count = 0;
    int ok = 0;
    int err = 0;
    long long totalMs = 0;
    long long maxMs = 0;
  };

  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Aggregates (mirrors the ts client._metrics record).
  MetricsBucket total;
  std::map<std::string, MetricsBucket> ops;

  MetricsFeature() : BaseFeature("metrics", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);

    total = MetricsBucket();
    ops.clear();
  }

  void prePoint(CtxPtr ctx) override {
    if (!active) return;
    starts[ctx->id] = fopt::foptNow(options)();
  }

  void preDone(CtxPtr ctx) override {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches PreDone before the pipeline errors.
    record(ctx, ctx->result && ctx->result->ok && !ctx->result->err);
  }

  void preUnexpected(CtxPtr ctx) override {
    record(ctx, false);
  }

private:
  std::map<std::string, long long> starts;

  void record(CtxPtr ctx, bool ok) {
    // Record once per operation: the missing start marker makes a second
    // call (PreDone followed by PreUnexpected on failure) a no-op.
    auto it = starts.find(ctx->id);
    if (it == starts.end()) return;
    long long start = it->second;
    starts.erase(it);

    long long dur = fopt::foptNow(options)() - start;
    if (dur < 0) dur = 0;

    std::string entity = "_";
    std::string opname = "_";
    if (ctx->op) {
      entity = ctx->op->entity;
      opname = ctx->op->name;
    }
    std::string key = entity + "." + opname;

    MetricsBucket& op = ops[key];

    bump(total, ok, dur);
    bump(op, ok, dur);
  }

  void bump(MetricsBucket& bucket, bool ok, long long dur) {
    bucket.count++;
    if (ok) bucket.ok++;
    else bucket.err++;
    bucket.totalMs += dur;
    if (dur > bucket.maxMs) bucket.maxMs = dur;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_METRICS_HPP
