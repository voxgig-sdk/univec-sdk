// Univec SDK — audit feature (mirrors java feature/AuditFeature.java).
// Audit trail. Emits a structured record for every operation — who (actor),
// what (entity + op), the outcome, and a correlation id. Records accumulate
// on the feature (bounded by `max`, default 1000) and, when a `sink` callback
// is supplied, are pushed to it. The actor is the per-call ctrl actor,
// falling back to the options `actor`, then "anonymous". Each operation is
// audited exactly once (the per-context seen marker — java ctx.out — is kept
// here keyed by ctx.id). Timestamps use the injectable `now` clock.

#ifndef SDK_FEATURE_AUDIT_HPP
#define SDK_FEATURE_AUDIT_HPP

#include <map>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class AuditFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  int seq = 0;

  // Activity tracking (mirrors the ts client._audit record).
  Value records = vlist();

  AuditFeature() : BaseFeature("audit", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    seq = 0;
  }

  void preDone(CtxPtr ctx) override {
    // Outcome reflects the actual result; a non-2xx reaches PreDone before
    // the pipeline errors.
    std::string outcome = "error";
    if (ctx->result && ctx->result->ok && !ctx->result->err) {
      outcome = "ok";
    }
    emit(ctx, outcome);
  }

  void preUnexpected(CtxPtr ctx) override {
    emit(ctx, "error");
  }

private:
  std::map<std::string, bool> seen;

  void emit(CtxPtr ctx, const std::string& outcome) {
    if (!active) return;

    // One record per operation (PreDone + a following PreUnexpected on a
    // failure must not double-log).
    if (seen.count(ctx->id) && seen[ctx->id]) return;
    seen[ctx->id] = true;

    seq++;

    std::string actor = "anonymous";
    std::string optActor = fopt::foptStr(options, "actor", "");
    if (!optActor.empty()) actor = optActor;
    if (ctx->ctrl && !ctx->ctrl->actor.empty()) actor = ctx->ctrl->actor;

    std::string entity = "_";
    std::string opname = "_";
    if (ctx->op) {
      entity = ctx->op->entity;
      opname = ctx->op->name;
    }

    Value record = vmap();
    map_put(record, "seq", Value(seq));
    map_put(record, "ts", Value((long long) fopt::foptNow(options)()));
    map_put(record, "actor", Value(actor));
    map_put(record, "entity", Value(entity));
    map_put(record, "op", Value(opname));
    map_put(record, "outcome", Value(outcome));
    map_put(record, "correlationId", Value(ctx->id));
    if (ctx->result) {
      map_put(record, "status", Value(ctx->result->status));
    }

    records.as_list()->push_back(record);
    int max = fopt::foptInt(options, "max", 1000);
    while ((int) records.as_list()->size() > max) {
      records.as_list()->erase(records.as_list()->begin());
    }

    Value sink = getp(options, "sink");
    if (sink.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      sink.as_injector()(inj, vlist({record}), std::string(""), Value::undef());
    }
  }
};

} // namespace sdk

#endif // SDK_FEATURE_AUDIT_HPP
