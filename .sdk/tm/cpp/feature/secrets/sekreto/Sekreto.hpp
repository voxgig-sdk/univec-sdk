// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Sekreto.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// sekreto: one interface for secrets, wherever they live.
//
// A Sekreto is an ordered chain of providers. `get` asks each in turn and
// returns the first hit, so an app can be configured from environment
// variables in development and a vault in production without changing a
// line of its own code.
//
// THE CORE INCLUDES NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
// SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
// read at most a local file; every other kind is a voxgig/plugin
// definition under plugins/, and a chain may name one only if the calling
// project handed it in through `plugins`. That is what keeps an SDK whose
// chain is `[dotenv, env]` from linking AWS request signing, seven HTTP
// vault clients and OpenSSL behind them. See
// docs/design/plugin-providers.md.
//
// A port of typescript/src/Sekreto.ts, which is canonical.

#ifndef SEKRETO_SEKRETO_HPP
#define SEKRETO_SEKRETO_HPP

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "Json.hpp"
#include "Provider.hpp"

namespace sekreto {

/// A secret name: dot-separated lowercase segments, e.g. `api.token`.
using Name = std::string;

/// How a Sekreto is built.
///
/// `plugins` is STATIC AND EXPLICIT: the calling project includes the
/// kinds it needs and passes them here, and a kind it did not pass is
/// unknown to this Sekreto. No dynamic discovery, no registry filled at
/// load, no module named by a string - the set of stores an app can reach
/// is not something to find out at run time, and a side effect of linking
/// is a thing a linker can drop.
struct SekretoOptions {
  /// The provider chain, in resolution order, declaratively.
  std::vector<ProviderSpec> providers;
  /// The provider kinds beyond the built-ins that `providers` may name.
  std::vector<Definition> plugins;
  /// Cache resolved values (default: true).
  bool cache = true;
};

/// Uppercase and lowercase the ASCII letters and nothing else. The C
/// library's `toupper` is locale-sensitive, and envkey must answer the
/// same in every locale on every port.
std::string asciiupper(const std::string& text);
std::string asciilower(const std::string& text);

/// Split on the literal dot, KEEPING empties, so `a.` is two segments (one
/// of them empty) and therefore not a valid name.
std::vector<std::string> segments(const std::string& name);

/// Is this a well-formed secret name?
bool validname(const std::string& name);
/// The same, for whatever a caller passed: anything that is not a string
/// is not a name. Never raises.
bool validname(const Json& name);

/// The name, or a SekretoError. Every entry point checks its name here.
Name checkname(const std::string& name);
Name checkname(const Json& name);

/// The environment-variable key for a name: `api.token` -> `API_TOKEN`.
/// The prefix is used verbatim, and is NOT uppercased.
std::string envkey(const std::string& name, const std::string& prefix = "");

/// Where a name lives in a KV vault.
struct VaultRef {
  std::string path;
  std::string field;
};

/// `api.token` -> `api` / `token`. A single-segment name has no path of
/// its own, so it becomes a secret of that name with the field `value`.
VaultRef vaultref(const std::string& name);

/// A name flattened to one segment: `api.token` -> `api_token` (GCP) or
/// `api-token` (Azure). With `-`, underscores flatten too, because Key
/// Vault's alphabet is letters, digits and hyphens only.
std::string flatname(const std::string& name, const std::string& sep);

/// The AWS SSM Parameter Store name: `db.pass.main` -> `/db/pass/main`,
/// or `/app/db/pass/main` under prefix `app`.
std::string awsparam(const std::string& name, const std::string& prefix = "");

/// Parse `.env` text into raw keys and values. There is no `.env`
/// standard, so this function is the specification; see the source.
Ordered parsedotenv(const std::string& text);
Ordered parsedotenv(const Json& text);

/// Replace known secret values in text with `[redacted]`. Only values of
/// four characters or more: shorter ones are too likely to appear in
/// ordinary text, and redacting them would make logs unreadable without
/// making them safer.
std::string redact(const std::string& text, const std::vector<std::string>& values);

/// The store name a provider answers to when nothing says otherwise:
/// `describe()` up to the first `:`.
std::string storename(const Provider& provider);

/// The secrets facade: a chain of providers plus a cache.
///
/// Two ways to read. `get` is transparent - it walks the chain and takes
/// the first hit, and the caller never learns which store answered.
/// `getfrom` is directed - it names the store, and only that store is
/// asked.
class Sekreto {
 public:
  /// A chain from declarative specs, built on a voxgig/plugin host: the
  /// catalog is the four built-ins plus whatever `plugins` names, and each
  /// spec becomes one instance on the host.
  ///
  /// Eager and in chain order, so a chain that cannot be built says so at
  /// once. Construction contacts nothing: `load` runs a definition's
  /// `define`, which builds the provider, `activate` takes it live, and
  /// the first network call is still the first lookup.
  explicit Sekreto(const SekretoOptions& options);

  /// A chain of providers already built. Nothing is declared on the host,
  /// so `host().list()` is empty - a live provider has no instance behind
  /// it, and never needed one.
  Sekreto(std::vector<std::shared_ptr<Provider>> providers,
          std::vector<std::string> names, bool docache = true);

  /// The voxgig/plugin host every spec'd provider is an instance of. Read
  /// it for introspection - `list()` names each store's ref and status -
  /// and nothing on it advances the chain.
  plugin::Host& host() const { return *host_; }
  /// The definitions this Sekreto can build: the built-ins plus what
  /// `plugins` handed in.
  plugin::Catalog& catalog() const { return *catalog_; }

  /// The secret, or a SekretoError if no provider has it.
  std::string get(const Name& name);
  /// The secret, or nothing. Named `tryget` because `try` is a keyword.
  std::optional<std::string> tryget(const Name& name);
  /// The secret from one named store, or a SekretoError.
  std::string getfrom(const std::string& store, const Name& name);
  /// The secret from one named store, or nothing. Naming a store that is
  /// not in the chain is an error, not a miss.
  std::optional<std::string> tryfrom(const std::string& store, const Name& name);

  bool has(const Name& name);
  bool hasin(const std::string& store, const Name& name);
  /// Every named secret at once. Missing ones are an error.
  Ordered all(const std::vector<Name>& names);

  /// A description of each provider, in resolution order.
  std::vector<std::string> sources() const;
  /// The name of each store `getfrom` can address, in order, deduped.
  std::vector<std::string> stores() const;

  /// Replace every value this Sekreto has resolved with `[redacted]`.
  std::string redact(const std::string& text) const;

  /// Drop cached values, so the next `get` asks the providers again.
  void refresh();
  /// Tear the chain down: every plugin instance is deactivated and
  /// unloaded, in reverse. Afterwards nothing resolves - but redaction
  /// still knows every value ever resolved.
  void close();

  /// Printed without its secrets. `cache` and `seen` are ordinary fields,
  /// so a derived printer would put every resolved secret into whatever
  /// formatted it. Note the literal spacing: an empty chain prints
  /// `Sekreto { stores: [  ] }`.
  std::string str() const;
  /// The same, as data: the store names and nothing else.
  Json tojson() const;

 private:
  /// One provider in the chain, under the store name it answers to, and
  /// the ref of the plugin instance that built it - empty for a live
  /// provider handed in directly, which no instance backs.
  struct Entry {
    std::string store;
    std::string ref;
    std::shared_ptr<Provider> provider;
  };

  struct Cached {
    std::string store;
    Name name;
    std::string value;
  };

  Entry declare(const ProviderSpec& spec);

  std::optional<std::string> resolve(const std::string& store, const Name& name,
                                     const std::vector<Entry>& useentries);

  plugin::CatalogPtr catalog_;
  plugin::HostPtr host_;
  std::vector<Entry> entries_;
  // A list, not a map: the store a value came from stays attached, and
  // redaction order does not vary between runs.
  std::vector<Cached> cache_;
  // Every value ever resolved, for redact(). Kept independently of the
  // read cache, so `cache: false` does not silently disable redaction.
  // Append-only for the object's life: neither refresh() nor close()
  // clears it.
  std::vector<std::string> seen_;
  bool docache_;
};

/// Make a Sekreto from declarative provider specs and the plugin kinds
/// they may name - the same shape the shared spec and an app's config file
/// use.
Sekreto makesekreto(const std::vector<ProviderSpec>& specs,
                    const std::vector<Definition>& plugins = {}, bool cache = true);

}  // namespace sekreto

#endif
