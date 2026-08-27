// Univec SDK — clienttrack feature (mirrors java feature/ClienttrackFeature.java).
// Client tracking. Establishes a stable per-client session id at construction
// and stamps identifying headers on every request: a `User-Agent`
// (`<clientName>/<clientVersion>`), an `X-Client-Id` (session), and a fresh
// per-request `X-Request-Id`. Header names, client name/version and the id
// generator (`idgen`) are configurable; caller-provided User-Agent /
// X-Client-Id values are never clobbered.

#ifndef SDK_FEATURE_CLIENTTRACK_HPP
#define SDK_FEATURE_CLIENTTRACK_HPP

#include <cstdio>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class ClienttrackFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  long long idseed = 1;

  // Activity tracking (mirrors the ts client._clienttrack record).
  std::string session = "";
  int requests = 0;
  std::string lastRequestId = "";
  std::string clientName = "";

  ClienttrackFeature() : BaseFeature("clienttrack", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    requests = 0;
  }

  void postConstruct(CtxPtr ctx) override {
    if (!active) return;
    session = fopt::foptStr(options, "sessionId", genid("session"));
    clientName = name();
  }

  void preRequest(CtxPtr ctx) override {
    if (!active) return;

    SpecPtr spec = ctx->spec;
    if (!spec) return;
    if (!spec->headers.is_map()) spec->headers = vmap();

    // Lazily establish the session when PostConstruct never fired.
    if (session.empty()) {
      session = fopt::foptStr(options, "sessionId", genid("session"));
    }

    Value h = fopt::foptMap(options, "headers");
    requests++;
    std::string requestId = genid("request");

    fopt::fheaderSetDefault(spec->headers, fopt::foptStr(h, "agent", "User-Agent"), name());
    fopt::fheaderSetDefault(spec->headers, fopt::foptStr(h, "client", "X-Client-Id"), session);
    map_put(spec->headers, fopt::foptStr(h, "request", "X-Request-Id"), Value(requestId));

    lastRequestId = requestId;
    clientName = name();
  }

private:
  std::string name() {
    std::string nm = fopt::foptStr(options, "clientName", "Univec-SDK");
    std::string version = fopt::foptStr(options, "clientVersion", "0.0.1");
    return nm + "/" + version;
  }

  unsigned long long nextRand() {
    idseed = (idseed * 1103515245LL + 12345LL) & 0x7fffffffLL;
    return (unsigned long long) idseed;
  }

  std::string genid(const std::string& kind) {
    Value idgen = getp(options, "idgen");
    if (idgen.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      Value r = idgen.as_injector()(inj, vlist({Value(kind)}), std::string(""), Value::undef());
      return r.is_string() ? r.as_string() : Struct::stringify(r);
    }
    unsigned a = (unsigned)(nextRand() % 0x1000000);
    unsigned b = (unsigned)(nextRand() % 0x1000000);
    unsigned c = (unsigned)(nextRand() % 0x1000000);
    std::string first = kind.empty() ? std::string("") : kind.substr(0, 1);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s-%06x%06x%06x", first.c_str(), a, b, c);
    std::string id(buf);
    if (id.size() > 20) id = id.substr(0, 20);
    return id;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_CLIENTTRACK_HPP
