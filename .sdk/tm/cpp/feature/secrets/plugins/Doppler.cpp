// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Doppler.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Doppler.hpp"

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// ---------------------------------------------------------------- doppler

/// Doppler.
///
/// The whole config is downloaded once - Doppler's own bulk endpoint - and
/// answered from memory, like a remote .env: `api.token` is the
/// `API_TOKEN` entry. A service token is config-scoped, so project and
/// config are only needed with broader tokens.
class DopplerProvider : public Provider {
 public:
  DopplerProvider(const std::string& token, const std::string& project,
                  const std::string& config, const std::string& addr)
      : token_(token), project_(project), config_(config), addr_(addr) {}

  std::optional<std::string> lookup(const std::string& name) override {
    load();
    // The `prefix` option is deliberately not consulted by this kind.
    return values_.get(envkey(name));
  }

  std::string describe() const override {
    return project_.empty() ? "doppler" : "doppler:" + project_ + "/" + config_;
  }

 private:
  void load() {
    if (loaded_) return;

    std::string useaddr = trimslash(first(addr_, "https://api.doppler.com"));
    checkaddr(useaddr);

    std::string url = useaddr + "/v3/configs/config/secrets/download?format=json";
    if (!project_.empty()) url += "&project=" + uriescape(project_);
    if (!config_.empty()) url += "&config=" + uriescape(config_);

    Ordered headers;
    headers.set("authorization", "Bearer " + token_);

    Answer res = fetchjson("GET", url, headers);

    if (200 != res.status || !res.body.isobj()) {
      throw SekretoError("sekreto: doppler error: " + std::to_string(res.status));
    }

    Ordered values;

    for (const auto& entry : res.body.objval) {
      std::optional<std::string> text = textof(entry.second);
      if (text.has_value()) values.set(entry.first, text.value());
    }

    // Only a successful load is remembered: a failed one retries.
    values_ = values;
    loaded_ = true;
  }

  std::string token_;
  std::string project_;
  std::string config_;
  std::string addr_;

  Ordered values_;
  bool loaded_ = false;
};

}  // namespace

Definition doppler() {
  return providerplugin("doppler", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<DopplerProvider>(spec.token, spec.project, spec.config, spec.addr);
  });
}

}  // namespace sekreto
