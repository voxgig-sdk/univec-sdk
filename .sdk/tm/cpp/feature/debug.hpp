// Univec SDK — debug feature (mirrors java feature/DebugFeature.java).
// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status and
// timing — on the feature's entries. Sensitive header values (matching
// `redact`) are masked. An optional `onEntry` callback receives each finished
// entry. `max` caps the buffer (default 100). The per-context entry marker
// (java ctx.out) is kept here keyed by ctx.id.

#ifndef SDK_FEATURE_DEBUG_HPP
#define SDK_FEATURE_DEBUG_HPP

#include <cctype>
#include <map>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class DebugFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Activity tracking (mirrors the ts client._debug record).
  Value entries = vlist();

  DebugFeature() : BaseFeature("debug", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
  }

  void preRequest(CtxPtr ctx) override {
    if (!active) return;

    std::string entity = "_";
    std::string opname = "_";
    if (ctx->op) {
      entity = ctx->op->entity;
      opname = ctx->op->name;
    }

    Value entry = vmap();
    map_put(entry, "op", Value(entity + "." + opname));
    map_put(entry, "start", Value((long long) fopt::foptNow(options)()));
    if (ctx->spec) {
      map_put(entry, "method", Value(ctx->spec->method));
      if (!ctx->spec->url.empty()) {
        map_put(entry, "url", Value(ctx->spec->url));
      } else {
        map_put(entry, "url", Value(ctx->spec->path));
      }
      map_put(entry, "headers", redact(ctx->spec->headers));
    }
    pending[ctx->id] = entry;
  }

  void preResponse(CtxPtr ctx) override {
    if (!active) return;

    Value entry = Helpers::toMapAny(getPending(ctx));
    if (!entry.is_map()) return;
    if (ctx->response) {
      map_put(entry, "status", Value(ctx->response->status));
      Value url = getp(entry, "url");
      if ((is_nullish(url) || (url.is_string() && url.as_string().empty())) && ctx->spec) {
        map_put(entry, "url", Value(ctx->spec->url));
      }
    }
  }

  void preDone(CtxPtr ctx) override {
    finish(ctx, true);
  }

  void preUnexpected(CtxPtr ctx) override {
    Value entry = Helpers::toMapAny(getPending(ctx));
    if (entry.is_map() && ctx->ctrl && ctx->ctrl->err) {
      map_put(entry, "error", Value(ctx->ctrl->err->getMessage()));
    }
    finish(ctx, false);
  }

private:
  std::map<std::string, Value> pending;

  Value getPending(CtxPtr ctx) {
    auto it = pending.find(ctx->id);
    return it == pending.end() ? Value::undef() : it->second;
  }

  void finish(CtxPtr ctx, bool ok) {
    // Finish once per operation: the marker is consumed here.
    Value entry = Helpers::toMapAny(getPending(ctx));
    if (!entry.is_map()) return;
    pending.erase(ctx->id);

    map_put(entry, "ok", Value(ok && (!ctx->result || ctx->result->ok)));
    long long start = Helpers::toLong(getp(entry, "start"), 0);
    long long dur = fopt::foptNow(options)() - start;
    if (dur < 0) dur = 0;
    map_put(entry, "durationMs", Value(dur));
    if (is_nullish(getp(entry, "status")) && ctx->result) {
      map_put(entry, "status", Value(ctx->result->status));
    }

    entries.as_list()->push_back(entry);
    int max = fopt::foptInt(options, "max", 100);
    while ((int) entries.as_list()->size() > max) {
      entries.as_list()->erase(entries.as_list()->begin());
    }

    Value onEntry = getp(options, "onEntry");
    if (onEntry.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      onEntry.as_injector()(inj, vlist({entry}), std::string(""), Value::undef());
    }
  }

  Value redact(const Value& headers) {
    Value out = vmap();
    if (!headers.is_map()) return out;

    std::vector<std::string> patterns = fopt::foptStrList(options, "redact");
    if (!fopt::foptList(options, "redact").is_list()) {
      patterns = {"authorization", "cookie", "set-cookie", "api-key",
                  "apikey", "x-api-key", "idempotency-key"};
    }
    for (const auto& kv : *headers.as_map()) {
      std::string lk = kv.first;
      for (auto& c : lk) c = static_cast<char>(std::tolower((unsigned char)c));
      bool masked = false;
      for (const auto& p : patterns) {
        if (lk == p) {
          masked = true;
          break;
        }
      }
      if (masked) {
        map_put(out, kv.first, Value("<redacted>"));
      } else {
        map_put(out, kv.first, kv.second);
      }
    }
    return out;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_DEBUG_HPP
