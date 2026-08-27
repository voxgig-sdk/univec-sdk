// Univec SDK — idempotency feature (mirrors java feature/IdempotencyFeature.java).
// Idempotency keys for mutating operations. Adds an `Idempotency-Key` header
// (name configurable via `header`) to unsafe requests so a server can
// de-duplicate retried writes. The key is set once, at PreRequest, before the
// request is built. A caller-supplied header is never overwritten
// (case-insensitive). The key generator is injectable (`keygen`).

#ifndef SDK_FEATURE_IDEMPOTENCY_HPP
#define SDK_FEATURE_IDEMPOTENCY_HPP

#include <cctype>
#include <cstdio>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class IdempotencyFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  long long kseed = 1;

  // Activity tracking (mirrors the ts client._idempotency record).
  int issued = 0;
  std::string last = "";

  IdempotencyFeature() : BaseFeature("idempotency", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
  }

  void preRequest(CtxPtr ctx) override {
    if (!active) return;

    SpecPtr spec = ctx->spec;
    if (!spec) return;

    if (!mutating(ctx)) return;

    std::string header = fopt::foptStr(options, "header", "Idempotency-Key");
    if (!spec->headers.is_map()) spec->headers = vmap();

    // Respect a key the caller already provided.
    if (fopt::fheaderHas(spec->headers, header)) return;

    std::string key = genkey();
    map_put(spec->headers, header, Value(key));

    issued++;
    last = key;
  }

private:
  static std::string upper(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::toupper((unsigned char)c));
    return s;
  }

  bool mutating(CtxPtr ctx) {
    std::vector<std::string> methods = fopt::foptStrList(options, "methods");
    if (!fopt::foptList(options, "methods").is_list()) {
      methods = {"POST", "PUT", "PATCH", "DELETE"};
    }
    std::string method = "";
    if (ctx->spec) method = upper(ctx->spec->method);
    if (!method.empty()) {
      for (const auto& m : methods) {
        if (upper(m) == method) return true;
      }
    }

    std::string opname = "";
    if (ctx->op) opname = ctx->op->name;
    std::vector<std::string> ops = fopt::foptStrList(options, "ops");
    if (!fopt::foptList(options, "ops").is_list()) {
      ops = {"create", "update", "remove"};
    }
    for (const auto& o : ops) {
      if (o == opname) return true;
    }
    return false;
  }

  unsigned long long nextRand() {
    kseed = (kseed * 1103515245LL + 12345LL) & 0x7fffffffLL;
    return (unsigned long long) kseed;
  }

  std::string genkey() {
    Value kg = getp(options, "keygen");
    if (kg.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      Value r = kg.as_injector()(inj, vlist(), std::string(""), Value::undef());
      return r.is_string() ? r.as_string() : Struct::stringify(r);
    }

    unsigned a = (unsigned)(nextRand() % 0x1000000);
    unsigned b = (unsigned)(nextRand() % 0x1000000);
    unsigned c = (unsigned)(nextRand() % 0x1000000);
    unsigned d = (unsigned)(nextRand() % 0x1000000);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%06x%06x%06x%06x", a, b, c, d);
    std::string key(buf);
    if (key.size() > 24) key = key.substr(0, 24);
    return key;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_IDEMPOTENCY_HPP
