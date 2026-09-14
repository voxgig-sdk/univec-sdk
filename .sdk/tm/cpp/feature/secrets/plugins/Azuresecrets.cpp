// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Azuresecrets.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Azuresecrets.hpp"

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// ------------------------------------------------------------------ azure

/// The Key Vault audience an Azure token is minted for.
const char* const AZURERESOURCE = "https://vault.azure.net";

/// Azure Key Vault.
///
/// `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
/// names allow nothing else), current version. The token comes from
/// config, then a client-credentials login when tenant/clientid/
/// clientsecret are given, then the IMDS managed-identity endpoint.
class AzuresecretsProvider : public Provider {
 public:
  AzuresecretsProvider(const std::string& vault, const std::string& token,
                       const std::string& tenant, const std::string& clientid,
                       const std::string& clientsecret, const std::string& loginaddr,
                       const std::string& imdsaddr, const std::string& apiversion)
      : vault_(vault),
        token_(token),
        tenant_(tenant),
        clientid_(clientid),
        clientsecret_(clientsecret),
        loginaddr_(loginaddr),
        imdsaddr_(imdsaddr),
        apiversion_(apiversion) {}

  std::optional<std::string> lookup(const std::string& name) override {
    if (vault_.empty()) throw SekretoError("sekreto: azure: no vault");

    // Only an explicit scheme is a URL; a vault NAMED httpvault must still
    // become https://httpvault.vault.azure.net.
    bool isurl = 0 == vault_.compare(0, 7, "http://") || 0 == vault_.compare(0, 8, "https://");
    std::string vaulturl = isurl ? vault_ : "https://" + vault_ + ".vault.azure.net";

    checkaddr(vaulturl);

    if (!livetoken_.has_value() || nowms() >= renewat_) {
      livetoken_ = login();
    }

    std::string url = trimslash(vaulturl) + "/secrets/" + flatname(name, "-") +
                      "?api-version=" + first(apiversion_, "7.4");

    Ordered headers;
    headers.set("authorization", "Bearer " + livetoken_.value_or(""));

    Answer res = fetchjson("GET", url, headers);

    if (404 == res.status) return std::nullopt;

    if (200 != res.status) {
      throw SekretoError("sekreto: azure error: " + std::to_string(res.status) + ": " +
                         bareurl(url));
    }

    return textof(res.body.get("value"));
  }

  std::string describe() const override { return "azuresecrets:" + vault_; }

 private:
  std::string login() {
    if (!token_.empty()) return token_;

    if (!tenant_.empty() && !clientid_.empty() && !clientsecret_.empty()) {
      std::string useloginaddr = first(loginaddr_, "https://login.microsoftonline.com");
      checkaddr(useloginaddr);

      std::string url = trimslash(useloginaddr) + "/" + tenant_ + "/oauth2/v2.0/token";
      std::string form = "grant_type=client_credentials&client_id=" + uriescape(clientid_) +
                         "&client_secret=" + uriescape(clientsecret_) +
                         "&scope=" + uriescape(std::string(AZURERESOURCE) + "/.default");

      Ordered headers;
      headers.set("content-type", "application/x-www-form-urlencoded");

      Answer res = fetchjson("POST", url, headers, form);

      std::optional<std::string> got = textof(res.body.get("access_token"));

      if (200 != res.status || !got.has_value() || got.value().empty()) {
        throw SekretoError("sekreto: azure login failed: " + std::to_string(res.status));
      }

      renewat_ = renewtime(res.body.get("expires_in"));

      return got.value();
    }

    std::string imds = trimslash(first(imdsaddr_, "http://169.254.169.254")) +
                       "/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" +
                       uriescape(AZURERESOURCE);

    Ordered headers;
    headers.set("Metadata", "true");

    Answer res = fetchjson("GET", imds, headers);

    std::optional<std::string> got = textof(res.body.get("access_token"));

    if (200 != res.status || !got.has_value() || got.value().empty()) {
      throw SekretoError(
          "sekreto: azure: no token, no client credentials, and IMDS did not answer");
    }

    // IMDS sends expires_in as a STRING, unlike everybody else.
    renewat_ = renewtime(res.body.get("expires_in"));

    return got.value();
  }

  std::string vault_;
  std::string token_;
  std::string tenant_;
  std::string clientid_;
  std::string clientsecret_;
  std::string loginaddr_;
  std::string imdsaddr_;
  std::string apiversion_;

  std::optional<std::string> livetoken_;
  double renewat_ = NEVER;
};

}  // namespace

Definition azuresecrets() {
  return providerplugin("azuresecrets", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<AzuresecretsProvider>(spec.vault, spec.token, spec.tenant,
                                                   spec.clientid, spec.clientsecret,
                                                   spec.loginaddr, spec.imdsaddr,
                                                   spec.apiversion);
  });
}

}  // namespace sekreto
