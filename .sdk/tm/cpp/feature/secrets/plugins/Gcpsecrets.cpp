// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Gcpsecrets.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Gcpsecrets.hpp"

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// -------------------------------------------------------------------- gcp

/// GCP Secret Manager.
///
/// `api.token` reads secret `api_token` (dots flattened to `_`; Secret
/// Manager ids have no hierarchy and reject dots), latest version. The
/// token comes from config, then GOOGLE_OAUTH_ACCESS_TOKEN, then the
/// GCE/GKE metadata server - so on Google's own platform no credential
/// configuration is needed at all.
///
/// The metadata call is plain http to a link-local host by platform design
/// and carries no credential, so `checkaddr` guards the Secret Manager
/// address instead.
class GcpsecretsProvider : public Provider {
 public:
  GcpsecretsProvider(const std::string& project, const std::string& token,
                     const std::string& addr, const std::string& metadataaddr)
      : project_(project), token_(token), addr_(addr), metadataaddr_(metadataaddr) {}

  std::optional<std::string> lookup(const std::string& name) override {
    if (project_.empty()) throw SekretoError("sekreto: gcp: no project");

    std::string useaddr = first(addr_, "https://secretmanager.googleapis.com");
    checkaddr(useaddr);

    if (!livetoken_.has_value() || nowms() >= renewat_) {
      livetoken_ = login();
    }

    std::string url = trimslash(useaddr) + "/v1/projects/" + project_ + "/secrets/" +
                      flatname(name, "_") + "/versions/latest:access";

    Ordered headers;
    headers.set("authorization", "Bearer " + livetoken_.value_or(""));

    Answer res = fetchjson("GET", url, headers);

    if (404 == res.status) return std::nullopt;

    if (200 != res.status) {
      throw SekretoError("sekreto: gcp error: " + std::to_string(res.status) + ": " + url);
    }

    std::string data;
    if (!res.body.get("payload").get("data").asstr(data)) return std::nullopt;

    std::string decoded;
    if (!unbase64(data, decoded)) {
      throw SekretoError("sekreto: gcp: undecodable secret");
    }

    return decoded;
  }

  std::string describe() const override { return "gcpsecrets:" + project_; }

 private:
  std::string usemetadataaddr() const {
    if (!metadataaddr_.empty()) return metadataaddr_;

    std::string host = envvar("GCE_METADATA_HOST");
    if (!host.empty()) return "http://" + host;

    return "http://metadata.google.internal";
  }

  std::string login() {
    std::string configured = first(token_, envvar("GOOGLE_OAUTH_ACCESS_TOKEN"));
    if (!configured.empty()) return configured;

    std::string url = trimslash(usemetadataaddr()) +
                      "/computeMetadata/v1/instance/service-accounts/default/token";

    Ordered headers;
    headers.set("Metadata-Flavor", "Google");

    Answer res = fetchjson("GET", url, headers);

    std::optional<std::string> got = textof(res.body.get("access_token"));

    if (200 != res.status || !got.has_value() || got.value().empty()) {
      throw SekretoError("sekreto: gcp: no token and metadata server did not answer");
    }

    renewat_ = renewtime(res.body.get("expires_in"));

    return got.value();
  }

  std::string project_;
  std::string token_;
  std::string addr_;
  std::string metadataaddr_;

  std::optional<std::string> livetoken_;
  double renewat_ = NEVER;
};

}  // namespace

Definition gcpsecrets() {
  return providerplugin("gcpsecrets", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<GcpsecretsProvider>(spec.project, spec.token, spec.addr,
                                                 spec.metadataaddr);
  });
}

}  // namespace sekreto
