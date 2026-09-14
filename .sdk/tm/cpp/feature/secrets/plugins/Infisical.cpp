// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Infisical.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Infisical.hpp"

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// -------------------------------------------------------------- infisical

/// Infisical.
///
/// `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
/// convention is environment-style keys) at a secret path in one
/// environment of a project. Auth is a token, or a universal-auth (machine
/// identity) login with clientid/clientsecret.
class InfisicalProvider : public Provider {
 public:
  InfisicalProvider(const std::string& addr, const std::string& token,
                    const std::string& clientid, const std::string& clientsecret,
                    const std::string& project, const std::string& environment,
                    const std::string& path)
      : addr_(addr),
        token_(token),
        clientid_(clientid),
        clientsecret_(clientsecret),
        project_(project),
        environment_(environment),
        path_(path) {}

  std::optional<std::string> lookup(const std::string& name) override {
    std::string useaddr = trimslash(first(addr_, "https://app.infisical.com"));
    checkaddr(useaddr);

    if (project_.empty() || environment_.empty()) {
      throw SekretoError("sekreto: infisical: no project/environment");
    }

    if (!livetoken_.has_value() || nowms() >= renewat_) {
      livetoken_ = login(useaddr);
    }

    // envkey here takes NO prefix.
    std::string url = useaddr + "/api/v3/secrets/raw/" + envkey(name) +
                      "?workspaceId=" + uriescape(project_) +
                      "&environment=" + uriescape(environment_) +
                      "&secretPath=" + uriescape(first(path_, "/"));

    Ordered headers;
    headers.set("authorization", "Bearer " + livetoken_.value_or(""));

    Answer res = fetchjson("GET", url, headers);

    if (404 == res.status) return std::nullopt;

    if (200 != res.status) {
      throw SekretoError("sekreto: infisical error: " + std::to_string(res.status));
    }

    return textof(res.body.get("secret").get("secretValue"));
  }

  std::string describe() const override {
    return "infisical:" + project_ + "/" + environment_;
  }

 private:
  std::string login(const std::string& useaddr) {
    if (!token_.empty()) return token_;

    if (clientid_.empty() || clientsecret_.empty()) {
      throw SekretoError("sekreto: infisical: no token and no client credentials");
    }

    Json payload = Json::obj({{"clientId", Json::str(clientid_)},
                              {"clientSecret", Json::str(clientsecret_)}});

    Ordered headers;
    headers.set("content-type", "application/json");

    Answer res = fetchjson("POST", useaddr + "/api/v1/auth/universal-auth/login", headers,
                           Json::stringify(payload));

    std::optional<std::string> got = textof(res.body.get("accessToken"));

    if (200 != res.status || !got.has_value() || got.value().empty()) {
      throw SekretoError("sekreto: infisical login failed: " + std::to_string(res.status));
    }

    // camelCase, unlike everyone else's expires_in.
    renewat_ = renewtime(res.body.get("expiresIn"));

    return got.value();
  }

  std::string addr_;
  std::string token_;
  std::string clientid_;
  std::string clientsecret_;
  std::string project_;
  std::string environment_;
  std::string path_;

  std::optional<std::string> livetoken_;
  double renewat_ = NEVER;
};

}  // namespace

Definition infisical() {
  return providerplugin("infisical", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<InfisicalProvider>(spec.addr, spec.token, spec.clientid,
                                               spec.clientsecret, spec.project,
                                               spec.environment, spec.path);
  });
}

}  // namespace sekreto
