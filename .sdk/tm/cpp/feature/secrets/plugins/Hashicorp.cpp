// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Hashicorp.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Hashicorp.hpp"

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// ------------------------------------------------------------- hashicorp

/// HashiCorp Vault.
///
/// KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
/// takes the `token` field of `data.data`. KV v1 reads
/// `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
/// here" - a miss - so a vault can sit in a chain with fallbacks.
///
/// A Vault Enterprise namespace rides X-Vault-Namespace, on logins as well
/// as reads. Instead of being handed a token the provider can log in:
/// Kubernetes auth or AppRole. A failed login is an error, never a miss.
class HashicorpProvider : public Provider {
 public:
  HashicorpProvider(const std::string& addr, const std::string& token,
                    const std::string& mount, const std::optional<int>& kv,
                    const std::string& vaultnamespace, const std::optional<AuthSpec>& auth)
      : addr_(addr),
        mount_(first(mount, "secret")),
        kv_(kv.value_or(2)),
        vaultnamespace_(vaultnamespace),
        auth_(auth) {
    if (!token.empty()) livetoken_ = token;

    // A version typo like kv: 3 must not quietly behave as v2 and turn its
    // 404s into misses; there is nothing safe to assume it meant.
    if (1 != kv_ && 2 != kv_) {
      throw SekretoError("sekreto: hashicorp: unsupported kv version: " +
                         std::to_string(kv_));
    }
  }

  std::optional<std::string> lookup(const std::string& name) override {
    checkaddr(addr_);

    if (!livetoken_.has_value() || nowms() >= renewat_) {
      livetoken_ = login();
    }

    VaultRef ref = vaultref(name);
    std::string base = trimslash(addr_) + "/v1/" + mount_;
    std::string url = (1 == kv_) ? base + "/" + ref.path : base + "/data/" + ref.path;

    Ordered headers = baseheaders();
    headers.set("X-Vault-Token", livetoken_.value_or(""));

    Answer res = fetchjson("GET", url, headers);

    // A 404 is this vault saying it does not hold the secret, so the chain
    // carries on. Anything else it refuses is a store that could not
    // answer.
    if (404 == res.status) return std::nullopt;

    if (200 != res.status) {
      throw SekretoError("sekreto: hashicorp error: " + std::to_string(res.status) + ": " + url);
    }

    Json data = (1 == kv_) ? res.body.get("data") : res.body.get("data").get("data");

    return textof(data.get(ref.field));
  }

  std::string describe() const override { return "hashicorp:" + addr_ + "/" + mount_; }

 private:
  Ordered baseheaders() const {
    Ordered out;
    if (!vaultnamespace_.empty()) out.set("X-Vault-Namespace", vaultnamespace_);
    return out;
  }

  std::string login() {
    if (!auth_.has_value()) {
      throw SekretoError("sekreto: hashicorp: no token and no auth method");
    }

    const AuthSpec& use = auth_.value();
    std::string url = trimslash(addr_) + "/v1/auth/" + first(use.mount, use.method) + "/login";

    Json payload;

    if ("kubernetes" == use.method) {
      std::string jwt = use.jwt;

      if (jwt.empty()) {
        std::string file =
            first(use.jwtfile, "/var/run/secrets/kubernetes.io/serviceaccount/token");

        Readout got = readfile(file);
        if (Readstate::Text != got.state) {
          throw SekretoError("sekreto: hashicorp: cannot read jwt file " + file);
        }

        jwt = trimtext(got.text);
      }

      payload = Json::obj({{"role", Json::str(use.role)}, {"jwt", Json::str(jwt)}});
    } else if ("approle" == use.method) {
      payload = Json::obj({{"role_id", Json::str(use.roleid)},
                           {"secret_id", Json::str(use.secretid)}});
    } else {
      throw SekretoError("sekreto: hashicorp: unknown auth method: " + use.method);
    }

    Answer res = fetchjson("POST", url, baseheaders(), Json::stringify(payload));

    std::optional<std::string> got = textof(res.body.get("auth").get("client_token"));

    if (200 != res.status || !got.has_value() || got.value().empty()) {
      throw SekretoError("sekreto: hashicorp login failed: " + std::to_string(res.status) +
                         ": " + url);
    }

    renewat_ = renewtime(res.body.get("auth").get("lease_duration"));

    return got.value();
  }

  std::string addr_;
  std::string mount_;
  int kv_;
  std::string vaultnamespace_;
  std::optional<AuthSpec> auth_;

  // The working token: a configured token is kept forever, a logged-in one
  // is renewed shortly before its lease runs out.
  std::optional<std::string> livetoken_;
  double renewat_ = NEVER;
};

}  // namespace

Definition hashicorp() {
  return providerplugin("hashicorp", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<HashicorpProvider>(spec.addr, spec.token, spec.mount, spec.kv,
                                                 spec.vaultnamespace, spec.auth);
  });
}

}  // namespace sekreto
