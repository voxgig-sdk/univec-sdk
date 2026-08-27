// Univec SDK — telemetry feature (mirrors java feature/TelemetryFeature.java).
// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id`/`X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Each span closes exactly
// once. The per-context span marker (java ctx.out) is kept here keyed by
// ctx.id, since the C++ CtxOut has no generic key/value store. Trace/span id
// generation (`idgen`) and the clock (`now`) are injectable.

#ifndef SDK_FEATURE_TELEMETRY_HPP
#define SDK_FEATURE_TELEMETRY_HPP

#include <cstdio>
#include <map>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class TelemetryFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  int seq = 0;

  // Activity tracking (mirrors the ts client._telemetry record).
  Value spans = vlist();
  int activeSpans = 0;

  TelemetryFeature() : BaseFeature("telemetry", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    seq = 0;
  }

  void prePoint(CtxPtr ctx) override {
    if (!active) return;

    std::string entity = "_";
    std::string opname = "_";
    if (ctx->op) {
      entity = ctx->op->entity;
      opname = ctx->op->name;
    }

    Value span = vmap();
    map_put(span, "traceId", Value(id("trace")));
    map_put(span, "spanId", Value(id("span")));
    map_put(span, "name", Value(entity + "." + opname));
    map_put(span, "start", Value((long long) fopt::foptNow(options)()));
    pending[ctx->id] = span;
    activeSpans++;
  }

  void preRequest(CtxPtr ctx) override {
    if (!active) return;

    Value span = Helpers::toMapAny(getPending(ctx));
    SpecPtr spec = ctx->spec;
    if (!span.is_map() || !spec) return;
    if (!spec->headers.is_map()) spec->headers = vmap();

    Value h = fopt::foptMap(options, "headers");
    std::string traceId = getp(span, "traceId").is_string() ? getp(span, "traceId").as_string() : "";
    std::string spanId = getp(span, "spanId").is_string() ? getp(span, "spanId").as_string() : "";
    map_put(spec->headers, fopt::foptStr(h, "trace", "X-Trace-Id"), Value(traceId));
    map_put(spec->headers, fopt::foptStr(h, "span", "X-Span-Id"), Value(spanId));
    map_put(spec->headers, fopt::foptStr(h, "parent", "traceparent"),
            Value("00-" + traceId + "-" + spanId + "-01"));
  }

  void preDone(CtxPtr ctx) override {
    close(ctx, ctx->result && ctx->result->ok && !ctx->result->err);
  }

  void preUnexpected(CtxPtr ctx) override {
    close(ctx, false);
  }

private:
  std::map<std::string, Value> pending;

  Value getPending(CtxPtr ctx) {
    auto it = pending.find(ctx->id);
    return it == pending.end() ? Value::undef() : it->second;
  }

  void close(CtxPtr ctx, bool ok) {
    // Close once per operation; a PreDone followed by a pipeline failure
    // (non-2xx) fires PreUnexpected too, which then finds no open span.
    Value span = Helpers::toMapAny(getPending(ctx));
    if (!span.is_map()) return;
    pending.erase(ctx->id);

    long long end = fopt::foptNow(options)();
    long long start = Helpers::toLong(getp(span, "start"), 0);
    long long dur = end - start;
    if (dur < 0) dur = 0;
    map_put(span, "end", Value(end));
    map_put(span, "durationMs", Value(dur));
    map_put(span, "ok", Value(ok));

    activeSpans--;
    spans.as_list()->push_back(span);

    Value exporter = getp(options, "exporter");
    if (exporter.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      exporter.as_injector()(inj, vlist({span}), std::string(""), Value::undef());
    }
  }

  std::string id(const std::string& kind) {
    Value idgen = getp(options, "idgen");
    if (idgen.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      Value r = idgen.as_injector()(inj, vlist({Value(kind)}), std::string(""), Value::undef());
      return r.is_string() ? r.as_string() : Struct::stringify(r);
    }
    // Deterministic-ish sequential id; unique within a client instance.
    seq++;
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%04x", seq);
    std::string n(buf);
    std::string prefix = (kind == "trace") ? "t" : "s";
    while (n.size() < 16) n.push_back('0');
    return prefix + n;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_TELEMETRY_HPP
