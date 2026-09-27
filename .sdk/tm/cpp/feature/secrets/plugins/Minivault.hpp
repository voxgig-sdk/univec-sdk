// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (cpp/plugins/Minivault.hpp)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A mini vault: every secret a project owns, encrypted, in ONE FILE.
//
// The store to reach for before there is a vault server. There is nothing
// to run and nothing to reach over a socket - the whole store is a single
// binary file - and the same chain that reads it in development reads
// HashiCorp or AWS in production by changing config, which is the reason
// sekreto exists.
//
// A PLUGIN, not a built-in: this kind needs crypto, which is the line the
// four built-in kinds stay behind. The calling project includes this
// header and passes what it declares to the Sekreto constructor
// (docs/design/plugin-providers.md).
//
// A chain READS. Writing is a deliberate act with an API of its own, so
// the definition publishes `vault` beside `provider` and `vaultof` reads
// it back off the host - which is what this header is mostly for.

#ifndef SEKRETO_PLUGINS_MINIVAULT_HPP
#define SEKRETO_PLUGINS_MINIVAULT_HPP

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "Provider.hpp"

namespace sekreto {

class Sekreto;

/// The key id a vault gets when a caller names none.
extern const char* const VAULT_MASTERKEY;

/// The PBKDF2-HMAC-SHA256 round count when a caller names none.
extern const int VAULT_ITERATIONS;

/// The export key the vault API is published under, beside the `provider`
/// key every kind publishes.
extern const char* const VAULT_EXPORT;

/// What a key may do. `grants` is empty for a master key, which reads and
/// writes every name there is.
///
/// A VALUE of const members over an immutable list, so the defect the
/// review round found in the canonical - a caller flipping its own
/// `write` bit on the record it was handed - does not compile.
class VaultKeyInfo {
 public:
  VaultKeyInfo(std::string key, bool master, bool write, std::vector<std::string> grants)
      : key_(std::move(key)),
        master_(master),
        write_(write),
        grants_(std::move(grants)) {}

  const std::string& key() const { return key_; }
  bool master() const { return master_; }
  bool write() const { return write_; }
  const std::vector<std::string>& grants() const { return grants_; }

 private:
  std::string key_;
  bool master_;
  bool write_;
  std::vector<std::string> grants_;
};

/// How a vault file is opened as one key.
struct VaultOptions {
  /// The vault file.
  std::string file;
  /// Which key to open with. Empty means VAULT_MASTERKEY.
  std::string key;
  /// What unwraps that key.
  std::string passphrase;
  /// The PBKDF2 round count used when this handle CREATES a key. Reading
  /// uses what the file records for the key being opened.
  int iterations = 0;
  /// Make the file, with this key as its master, if it is not there.
  ///
  /// Off by default. A missing vault is far more often a broken
  /// deployment than a new one, and a store that invents itself where a
  /// real vault was meant to be answers every read with a miss.
  bool create = false;
};

/// What mints a restricted key.
struct GrantSpec {
  /// The id the new key answers to.
  std::string key;
  /// What unwraps it. Nothing else does, and no master can recover it - a
  /// lost restricted passphrase is re-granted, never read back.
  std::string passphrase;
  /// The names the key may read. A name that does not exist yet is
  /// allowed and means what it says: the key reads it once a master
  /// writes it.
  std::vector<std::string> names;
  /// Whether it may overwrite the values it can read.
  bool write = false;
  /// PBKDF2 rounds for this key, defaulting to the opening handle's.
  int iterations = 0;
};

namespace minivaultfile {
struct Sealed;
struct Vault;
}  // namespace minivaultfile

/// A handle on one vault file, opened as ONE key.
///
/// Every method answers as that key: `list` shows the names it may read,
/// `get` answers for those and misses on the rest, and the master-only
/// methods throw for any other key. Nothing is read or derived until the
/// first call that needs the file, so putting a vault in a chain costs no
/// key derivation until a secret is actually wanted.
///
/// A refusal is a thrown SekretoError, as everywhere else in this port.
class MiniVault {
 public:
  MiniVault(std::string file, std::string key, std::string passphrase, int iterations,
            bool create);
  ~MiniVault();

  MiniVault(const MiniVault&) = delete;
  MiniVault& operator=(const MiniVault&) = delete;

  /// The vault file this handle reads.
  const std::string& file() const { return file_; }
  /// The key id this handle opens with.
  const std::string& key() const { return key_; }

  /// Derive the key and read the file NOW rather than at first use.
  VaultKeyInfo open();
  /// Forget the derived keys. The next call opens again.
  void close();

  /// The names this key can read, sorted.
  std::vector<std::string> list();
  /// The value, or nothing. A name the vault does not hold and a name
  /// this key was not granted are both a miss.
  std::optional<std::string> get(const std::string& name);
  bool has(const std::string& name);

  /// Write a value. A master writes any name; a restricted key holding
  /// `write` overwrites the names it was granted, and creates none.
  void set(const std::string& name, const std::string& value);
  /// Drop a name. Master only.
  void remove(const std::string& name);

  /// Every key in the file, with what it may do. Master only.
  std::vector<VaultKeyInfo> keys();
  /// Mint a restricted key. Master only.
  void grant(const GrantSpec& spec);
  /// Drop a key. Master only.
  ///
  /// Anyone who already copied the file keeps whatever that key could
  /// read, so revoking bars future reads of the LIVE file and `rotate` is
  /// what takes a secret back.
  void revoke(const std::string& key);
  /// Take a new root key, re-encrypt every value under it, and DROP EVERY
  /// OTHER KEY. Master only.
  ///
  /// The other keys go because they must: their rings are sealed under
  /// passphrases this process does not have, so there is no way to hand
  /// them keys they can unwrap. Re-grant afterwards.
  void rotate();

 private:
  minivaultfile::Vault read();
  std::vector<uint8_t> rootof(const std::string& what);
  std::optional<std::vector<uint8_t>> keyfor(const std::string& name);
  void save(const minivaultfile::Vault& file);
  void putnew(const minivaultfile::Vault& file);
  minivaultfile::Vault fresh(const std::string& keyid, const std::string& passphrase,
                             int iterations);

  std::string file_;
  std::string key_;
  std::string passphrase_;
  int iterations_;
  bool create_;

  bool opened_ = false;
  bool master_ = false;
  bool write_ = false;
  std::vector<uint8_t> root_;
  std::map<std::string, std::vector<uint8_t>> grants_;
  std::unique_ptr<minivaultfile::Sealed> ring_;
};

/// Make a vault file and answer a handle on its master key.
///
/// Refuses a file that is already there: a vault is created once, and
/// overwriting one discards every secret in it along with every key that
/// could read them.
std::shared_ptr<MiniVault> createvault(const VaultOptions& options);

/// Open a vault file as one key. The handle is LAZY: nothing is read, and
/// no passphrase is stretched, until a call needs the file.
std::shared_ptr<MiniVault> openvault(const VaultOptions& options);

/// The `minivault` provider kind, as a voxgig/plugin definition.
Definition minivault();

/// The vault behind a store in a chain, as its programmatic API.
///
/// With no store named, the unqualified alias answers: one vault in the
/// chain resolves whatever it is called, and two throw rather than
/// picking one.
std::shared_ptr<MiniVault> vaultof(const Sekreto& secrets, const std::string& store = "");

}  // namespace sekreto

#endif
