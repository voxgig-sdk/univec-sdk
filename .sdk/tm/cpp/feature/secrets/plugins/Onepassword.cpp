// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Onepassword.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Onepassword.hpp"

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// -------------------------------------------------------------- 1password

/// 1Password, through a Connect server.
///
/// The item titled `api.token` (titles keep their dots), in the named
/// vault. The value is the field with purpose PASSWORD, or the field
/// labelled `value`. A vault that cannot be found is an ERROR - config
/// names it, so its absence is a broken store, not a missing secret.
class OnepasswordProvider : public Provider {
 public:
  OnepasswordProvider(const std::string& addr, const std::string& token,
                      const std::string& vault)
      : addr_(addr), token_(token), vault_(vault) {}

  std::optional<std::string> lookup(const std::string& name) override {
    checkname(name);

    std::string useaddr = trimslash(addr_);
    if (useaddr.empty()) throw SekretoError("sekreto: onepassword: no addr");
    checkaddr(useaddr);

    if (!vaultid_.has_value()) vaultid_ = resolvevault(useaddr);

    std::string id = vaultid_.value();

    std::string filter = uriescape("title eq \"" + name + "\"");
    Answer found =
        fetchjson("GET", useaddr + "/v1/vaults/" + id + "/items?filter=" + filter, auth());

    if (200 != found.status || !found.body.isarr()) {
      throw SekretoError("sekreto: onepassword error: " + std::to_string(found.status) +
                         ": finding " + name);
    }

    if (found.body.arrval.empty()) return std::nullopt;

    std::string itemid = textof(found.body.arrval[0].get("id")).value_or("");
    Answer item =
        fetchjson("GET", useaddr + "/v1/vaults/" + id + "/items/" + itemid, auth());

    if (200 != item.status) {
      throw SekretoError("sekreto: onepassword error: " + std::to_string(item.status) +
                         ": reading " + name);
    }

    Json fields = item.body.get("fields");
    if (!fields.isarr()) return std::nullopt;

    // Two full passes, in order: a password field wins over a field merely
    // labelled `value`.
    for (const Json& field : fields.arrval) {
      std::string purpose;
      if (field.get("purpose").asstr(purpose) && "PASSWORD" == purpose) {
        return textof(field.get("value"));
      }
    }

    for (const Json& field : fields.arrval) {
      std::string label;
      if (field.get("label").asstr(label) && "value" == label) {
        return textof(field.get("value"));
      }
    }

    return std::nullopt;
  }

  std::string describe() const override { return "onepassword:" + vault_; }

 private:
  Ordered auth() const {
    Ordered out;
    out.set("authorization", "Bearer " + token_);
    return out;
  }

  std::string resolvevault(const std::string& useaddr) {
    if (vault_.empty()) throw SekretoError("sekreto: onepassword: no vault");

    Answer res = fetchjson("GET", useaddr + "/v1/vaults", auth());

    if (200 != res.status || !res.body.isarr()) {
      throw SekretoError("sekreto: onepassword error: " + std::to_string(res.status) +
                         ": listing vaults");
    }

    for (const Json& entry : res.body.arrval) {
      std::string id = textof(entry.get("id")).value_or("");
      std::string name = textof(entry.get("name")).value_or("");

      if (vault_ == id || vault_ == name) return id;
    }

    throw SekretoError("sekreto: onepassword: no vault named " + vault_);
  }

  std::string addr_;
  std::string token_;
  std::string vault_;

  std::optional<std::string> vaultid_;
};

}  // namespace

Definition onepassword() {
  return providerplugin("onepassword", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<OnepasswordProvider>(spec.addr, spec.token, spec.vault);
  });
}

}  // namespace sekreto
