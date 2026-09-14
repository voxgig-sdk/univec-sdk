// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Secretspec.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Secretspec.hpp"

#include "Proc.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

namespace {

// ------------------------------------------------------------- secretspec

/// SecretSpec (https://secretspec.dev).
///
/// A declaration - a `secretspec.toml` naming the secrets a project needs
/// - plus a chain of its own backends to satisfy them from. `backend`
/// selects one of those (`--provider`) and is called `backend` here only
/// because `provider` already means something else in this library.
///
/// A reason is required, not optional: SecretSpec records every read in an
/// audit log and refuses to read at all without one.
class SecretspecProvider : public Provider {
 public:
  SecretspecProvider(const std::string& command, const std::string& file,
                     const std::string& profile, const std::string& backend,
                     const std::string& reason, const std::string& prefix)
      : command_(first(command, "secretspec")),
        file_(file),
        profile_(profile),
        backend_(backend),
        reason_(reason),
        prefix_(prefix) {}

  std::optional<std::string> lookup(const std::string& name) override {
    std::string key = envkey(name, prefix_);

    // `--file` comes BEFORE the subcommand; everything else after it.
    std::vector<std::string> argv{command_};
    if (!file_.empty()) {
      argv.push_back("--file");
      argv.push_back(file_);
    }
    argv.push_back("get");
    argv.push_back(key);
    if (!backend_.empty()) {
      argv.push_back("--provider");
      argv.push_back(backend_);
    }
    if (!profile_.empty()) {
      argv.push_back("--profile");
      argv.push_back(profile_);
    }
    argv.push_back("--reason");
    argv.push_back(first(reason_, "sekreto"));

    Ran ran = runcmd(argv, processenv(), command_);

    if (0 == ran.status) {
      // The value and one newline, and nothing else.
      return dropnewline(ran.out);
    }

    if (secretspecmiss(ran.why, key)) return std::nullopt;

    throw SekretoError("sekreto: secretspec error: " +
                       (ran.why.empty() ? "exit " + std::to_string(ran.status) : ran.why));
  }

  std::string describe() const override {
    return backend_.empty() ? "secretspec" : "secretspec:" + backend_;
  }

 private:
  std::string command_;
  std::string file_;
  std::string profile_;
  std::string backend_;
  std::string reason_;
  std::string prefix_;
};

}  // namespace

// MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
// `Provider backend 'keyring' not found`, which is a store that could not
// answer at all - and reading that as a miss is the worst failure this
// library has, because the chain then falls through to a weaker store
// without saying so. The key is required to appear, so the two cannot be
// confused.
bool secretspecmiss(const std::string& why, const std::string& key) {
  return std::string::npos != why.find("Secret '" + key + "' not found");
}

Definition secretspec() {
  return providerplugin("secretspec", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<SecretspecProvider>(spec.command, spec.file, spec.profile,
                                                spec.backend, spec.reason, spec.prefix);
  });
}

}  // namespace sekreto
