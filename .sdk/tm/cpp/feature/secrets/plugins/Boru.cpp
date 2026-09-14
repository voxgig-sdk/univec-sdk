// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Boru.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Boru.hpp"

#include "Httpjson.hpp"
#include "Proc.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// ------------------------------------------------------------------ boru

/// A boru vault.
///
/// Two ways in, both boru's own. With no `addr`, the CLI:
/// `boru vault get --reveal <alias>` prints the secret on stdout and
/// nothing else; the passphrase is read by boru itself from
/// BORU_VAULT_PASSPHRASE, is never accepted as config, and never reaches a
/// command line where the process table would publish it.
///
/// With an `addr`, boru's wire protocol: a read-only, HashiCorp-shaped
/// provision API. A boru alias KEEPS its dots, so `api.token` is the
/// single path segment `api.token` - not the `api`/`token` split a
/// HashiCorp KV gets - and the value is the `value` field.
class BoruProvider : public Provider {
 public:
  BoruProvider(const std::string& command, const std::string& namespace_,
               const std::string& home, const std::string& addr, const std::string& token,
               const std::string& mount)
      : command_(first(command, "boru")),
        namespace_(namespace_),
        home_(home),
        addr_(trimslash(addr)),
        token_(token),
        mount_(first(mount, "secret")) {}

  std::optional<std::string> lookup(const std::string& name) override {
    checkname(name);

    if (!addr_.empty()) return wirelookup(name);

    // The CLI alias is namespace-qualified with a COLON; the wire one with
    // a slash. Both are boru's own spellings.
    std::string alias = namespace_.empty() ? name : namespace_ + ":" + name;

    std::vector<std::string> environment = processenv();
    if (!home_.empty()) setenvvar(environment, "BORU_HOME", home_);

    Ran ran = runcmd({command_, "vault", "get", "--reveal", alias}, environment, command_);

    if (0 == ran.status) {
      // boru prints the value and one newline, and nothing else.
      return dropnewline(ran.out);
    }

    // "no alias named" is boru saying it does not hold this secret, which
    // is a miss: the chain carries on. A locked vault or a wrong passphrase
    // is not a miss - treating it as one would fall through to a weaker
    // store without saying so.
    if (borumiss(ran.why)) return std::nullopt;

    throw SekretoError("sekreto: boru vault error: " +
                       (ran.why.empty() ? "exit " + std::to_string(ran.status) : ran.why));
  }

  std::string describe() const override {
    if (!addr_.empty()) return "boru:" + addr_;
    return namespace_.empty() ? "boru" : "boru:" + namespace_;
  }

 private:
  std::optional<std::string> wirelookup(const std::string& name) {
    checkaddr(addr_);

    std::string alias = namespace_.empty() ? name : namespace_ + "/" + name;
    std::string url = addr_ + "/v1/" + mount_ + "/data/" + alias;

    Ordered headers;
    headers.set("X-Vault-Token", token_);

    Answer res = fetchjson("GET", url, headers);

    if (404 == res.status) return std::nullopt;

    if (200 != res.status) {
      throw SekretoError("sekreto: boru serve error: " + std::to_string(res.status) + ": " + url);
    }

    return textof(res.body.get("data").get("data").get("value"));
  }

  std::string command_;
  std::string namespace_;
  std::string home_;
  std::string addr_;
  std::string token_;
  std::string mount_;
};

}  // namespace

bool borumiss(const std::string& why) {
  return std::string::npos != why.find("no alias named");
}

Definition boru() {
  return providerplugin("boru", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<BoruProvider>(spec.command, spec.namespace_, spec.home, spec.addr,
                                          spec.token, spec.mount);
  });
}

}  // namespace sekreto
