// Univec SDK — proxy feature (mirrors java feature/ProxyFeature.java).
// Outbound HTTP(S) proxy support. Wraps the active transport and annotates
// each request's fetch definition with the proxy target (`fetchdef.proxy`).
// The proxy target comes from options (`url`) or, when `fromEnv` is set, the
// standard HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. Hosts
// matching `noProxy` bypass the proxy.

#ifndef SDK_FEATURE_PROXY_HPP
#define SDK_FEATURE_PROXY_HPP

#include <cstdlib>
#include <initializer_list>
#include <regex>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class ProxyFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  std::vector<std::string> noProxy;

  // Activity tracking (mirrors the ts client._proxy record).
  int routed = 0;
  std::string url = "";

  ProxyFeature() : BaseFeature("proxy", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
    if (!active) return;

    url = fopt::foptStr(options, "url", "");
    bool hasNoProxy = fopt::foptList(options, "noProxy").is_list();
    std::vector<std::string> noProxyRaw = fopt::foptStrList(options, "noProxy");

    if (fopt::foptBool(options, "fromEnv", false)) {
      if (url.empty()) {
        url = firstEnv({"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"});
      }
      if (!hasNoProxy) {
        std::string np = firstEnv({"NO_PROXY", "no_proxy"});
        if (!np.empty()) {
          noProxyRaw = splitComma(np);
          hasNoProxy = true;
        }
      }
    }

    noProxy.clear();
    if (hasNoProxy) {
      for (std::string np : noProxyRaw) {
        np = trim(np);
        if (!np.empty()) noProxy.push_back(np);
      }
    }

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& u,
                                          const Value& fetchdef) -> Value {
      return inner(ctx2, u, route(u, fetchdef));
    };
  }

private:
  Value route(const std::string& u, const Value& fetchdef) {
    if (url.empty() || bypass(u)) {
      return fetchdef;
    }

    // Shallow copy of the fetch def (values shared), annotated with proxy.
    Value out = vmap();
    if (fetchdef.is_map()) {
      for (const auto& kv : *fetchdef.as_map()) map_put(out, kv.first, kv.second);
    }
    map_put(out, "proxy", Value(url));

    routed++;
    return out;
  }

  bool bypass(const std::string& u) {
    if (noProxy.empty()) return false;
    std::string host = u;
    static const std::regex HOST_RE("^[a-z]+://([^/:]+)", std::regex::icase);
    std::smatch mm;
    if (std::regex_search(u, mm, HOST_RE)) {
      host = mm[1].str();
    }
    for (const auto& np : noProxy) {
      if (np == "*") return true;
      std::string suffix = (!np.empty() && np[0] == '.') ? np.substr(1) : np;
      if (host == np || endsWith(host, "." + suffix)) {
        return true;
      }
    }
    return false;
  }

  static bool endsWith(const std::string& s, const std::string& suf) {
    return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
  }

  static std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
  }

  static std::vector<std::string> splitComma(const std::string& s) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
      size_t comma = s.find(',', start);
      if (comma == std::string::npos) {
        out.push_back(s.substr(start));
        break;
      }
      out.push_back(s.substr(start, comma - start));
      start = comma + 1;
    }
    return out;
  }

  static std::string firstEnv(std::initializer_list<const char*> names) {
    for (const char* name : names) {
      const char* v = std::getenv(name);
      if (v != nullptr && v[0] != '\0') return std::string(v);
    }
    return "";
  }
};

} // namespace sdk

#endif // SDK_FEATURE_PROXY_HPP
