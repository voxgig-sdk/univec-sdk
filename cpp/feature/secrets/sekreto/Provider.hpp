// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Provider.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// What a provider is, what its declarative form looks like, and how a
// provider kind becomes a voxgig/plugin definition.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or nothing to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//
// A MISS is `std::nullopt` and a FAILURE is a thrown SekretoError. They
// are never interchangeable: a store that could not answer must not read
// as a store that does not hold the secret, or the chain falls quietly
// through to a weaker one.
//
// This is the bottom of the core: the error, the ordered map every spec
// and every signature is written in, the provider interface, the
// declarative form of a provider, and the bridge to voxgig/plugin. It
// includes nothing of sekreto's, which is what lets everything else
// include it.
//
// A port of typescript/src/provider/support.ts, which is canonical.

#ifndef SEKRETO_PROVIDER_HPP
#define SEKRETO_PROVIDER_HPP

#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// voxgig/plugin: the catalog a definition is registered in, and the
// dynamic value an instance carries its options as. AGENTS.md rule 3's
// one Voxgig dependency, and rule 4 is why the core takes it.
#include "../plugin/catalog.hpp"
#include "../plugin/host.hpp"
#include "../plugin/value.hpp"

namespace sekreto {

/// Anything sekreto refuses to do: a bad name, a missing secret, a
/// provider that could not be reached.
///
/// The message is the whole contract - no code, no fields, no cause - and
/// the shared spec pins it byte for byte.
class SekretoError : public std::runtime_error {
 public:
  explicit SekretoError(const std::string& message) : std::runtime_error(message) {}
};

/// An insertion-ordered string map.
///
/// `std::map` orders by key and `std::unordered_map` by nothing at all;
/// the spec compares whole maps, and a signed AWS payload's field order is
/// part of what was signed. So this is a vector of pairs.
class Ordered {
 public:
  std::vector<std::pair<std::string, std::string>> pairs;

  bool has(const std::string& key) const;
  /// The value, or nothing. Absence is nothing; an empty string is a value.
  std::optional<std::string> get(const std::string& key) const;
  /// Insert, or overwrite in place so the original position is kept.
  void set(const std::string& key, const std::string& value);
  bool empty() const { return pairs.empty(); }
};

class Provider {
 public:
  virtual ~Provider() = default;

  /// The value, or nothing if this provider does not have it. May throw
  /// SekretoError when the store could not answer at all.
  virtual std::optional<std::string> lookup(const std::string& name) = 0;

  /// A short description, shown by `Sekreto::sources()`. It must lead with
  /// the kind: everything before the first `:` is the default store name.
  virtual std::string describe() const = 0;
};

/// Logging in to a vault instead of being handed a token. `method` is
/// `kubernetes` or `approle`; `mount` defaults to the method name.
struct AuthSpec {
  std::string method;
  std::string mount;
  /// kubernetes: the Vault role to log in as.
  std::string role;
  /// kubernetes: the service-account JWT itself (tests).
  std::string jwt;
  /// kubernetes: where the JWT lives; the conventional pod path by default.
  std::string jwtfile;
  /// approle: the role and secret ids.
  std::string roleid;
  std::string secretid;

  /// Printed without its credentials. A derived printer would put the
  /// service-account JWT and the AppRole secret id into
  /// `log("bad chain: " + spec)`, which is what someone writes when a
  /// chain will not build.
  std::string str() const;
};

/// The declarative form of a provider, as used in config and in the shared
/// spec. `kind` names a built-in or a plugin; everything else is that
/// kind's own, and a plugin reads it back off its instance's options.
///
/// String fields default to the empty string rather than to an optional:
/// "not configured" and "configured empty" mean the same thing everywhere
/// in this library.
struct ProviderSpec {
  std::string kind;
  /// The store name `Sekreto::getfrom` addresses. Defaults to `kind`.
  std::string name;
  std::string prefix;
  /// dotenv: the file to read. secretspec: the declaration to read.
  std::string file;
  /// memory: literal values, keyed like environment variables.
  Ordered values;
  /// file: the directory of one-secret-per-file entries.
  std::string dir;
  /// hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the base URL.
  std::string addr;
  /// hashicorp / boru (wire) / gcp / azure / 1password / doppler / infisical: the token.
  std::string token;
  /// hashicorp / boru (wire): the KV mount (default `secret`).
  std::string mount;
  /// hashicorp: KV engine version, 1 or 2 (default 2).
  std::optional<int> kv;
  /// hashicorp: Vault Enterprise namespace (X-Vault-Namespace).
  std::string vaultnamespace;
  /// hashicorp: log in for a token instead of being handed one.
  std::optional<AuthSpec> auth;
  /// boru / secretspec: the executable to run.
  std::string command;
  /// secretspec: the profile to read (`--profile`).
  std::string profile;
  /// secretspec: which of ITS backends to read from (`--provider`). Named
  /// `backend` here because `provider` already means a sekreto provider.
  std::string backend;
  /// secretspec: the audit reason recorded for the read (`--reason`).
  std::string reason;
  /// boru: the namespace qualifying the alias.
  std::string namespace_;
  /// boru: the vault home, passed as BORU_HOME.
  std::string home;
  /// aws: region and credentials; the standard AWS_* variables fill the rest.
  std::string region;
  std::string keyid;
  std::string secret;
  std::string session;
  /// gcp / doppler / infisical: the project, however that store names it.
  std::string project;
  /// azure: the Key Vault name or full URL. 1password: the vault name or id.
  std::string vault;
  /// azure: client-credential login. infisical: universal-auth login.
  std::string tenant;
  std::string clientid;
  std::string clientsecret;
  /// azure: where to log in / where IMDS answers. gcp: the metadata server.
  std::string loginaddr;
  std::string imdsaddr;
  std::string metadataaddr;
  /// azure: the Key Vault API version (default 7.4).
  std::string apiversion;
  /// doppler: the config slug (with `project`).
  std::string config;
  /// infisical: the environment slug and secret path.
  std::string environment;
  std::string path;

  /// Printed without its credentials. See AuthSpec::str.
  std::string str() const;
};

// --- providers as voxgig/plugin definitions --------------------------

/// A provider kind, as voxgig/plugin holds it. A definition is data with
/// functions in it, so it is a value a calling project passes in - never
/// a class to extend and never a registry to fill.
using Definition = plugin::DefinitionPtr;

/// How a kind builds its provider from the spec its instance was declared
/// with. A refusal is a thrown SekretoError.
using Make = std::function<std::shared_ptr<Provider>(const ProviderSpec&)>;

/// The export key under which a provider definition publishes the
/// provider it built. `Sekreto` reads `<ref>/provider` off the host.
extern const char* const PROVIDER_EXPORT;

/// The voxgig/plugin error code a SekretoError travels under when it is
/// thrown inside a definition's `define`.
///
/// plugin wraps a code-less error raised by a callback as
/// `plugin_define_failed`, and keeps an error that already carries a
/// code. A provider that refuses its own configuration - `kv: 3`, a
/// missing project - throws a SekretoError, and that message is pinned by
/// the spec byte for byte, so it must come back out of the host exactly
/// as it went in. `providerplugin` gives it this code on the way in;
/// `Sekreto` turns it back into a SekretoError on the way out.
extern const char* const ERROR_CODE;

/// A provider kind, as a voxgig/plugin definition.
///
/// This is the whole bridge between the two libraries. The definition's
/// `name` is the `kind` a ProviderSpec names; its `define` reads the spec
/// off the instance's options, builds the provider with `make`, and
/// exports it. Nothing runs at `activate`: a provider opens nothing until
/// its first lookup, so there is nothing to capture - a provider that does
/// hold a resource acquires it there and lets the instance scope unwind
/// it.
///
/// Every built-in and every plugin is made this way, so a custom provider
/// kind is one call:
///
///     Definition mystore = providerplugin(
///         "mystore", [](const ProviderSpec& spec) {
///           return std::make_shared<MyStore>(spec.addr);
///         });
Definition providerplugin(const std::string& kind, Make make);

/// A spec as the options map a plugin instance carries: one key per field
/// that is set, named as the field is - the spec's own key names in every
/// port.
plugin::V optionsof(const ProviderSpec& spec);

/// The spec a plugin instance's options describe: the inverse of
/// `optionsof`, and what a definition's `define` hands to its `make`.
ProviderSpec specof(const plugin::V& options);

// --- the provider slots ----------------------------------------------

// voxgig/plugin's value model carries numbers, strings, lists and maps -
// not pointers - so a definition's `define` cannot export the provider it
// built. It leaves the provider HERE and exports the ticket; `Sekreto`
// reads the ticket back off the host and takes the provider, which empties
// the slot again. The same shape zig's port uses, for the same reason.
//
// A slot is claimed exactly once, so nothing accumulates: between two
// constructions the table is empty, and `providerslots()` says so. Two
// threads building chains at once would share it, and this port - like the
// plugin port under it - does not claim to support that.

/// Park a freshly built provider and answer its ticket.
double providerslot(const std::shared_ptr<Provider>& provider);
/// Take the provider a ticket names, emptying the slot. Nothing, if the
/// ticket names no slot.
std::shared_ptr<Provider> takeprovider(double ticket);
/// The next ticket that will be issued: a mark to discard back to when a
/// declaration fails after its `define` has already built something.
double providermark();
/// Drop every slot filled since `mark`.
void providerdiscard(double mark);
/// How many slots are filled. Zero everywhere except inside a `define`.
size_t providerslots();

}  // namespace sekreto

#endif
