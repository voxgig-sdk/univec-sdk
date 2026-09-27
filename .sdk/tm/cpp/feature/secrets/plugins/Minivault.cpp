// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (cpp/plugins/Minivault.cpp)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Minivault.hpp"

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>

#include "Json.hpp"
#include "Providers.hpp"
#include "Sekreto.hpp"

// THE SECOND FILE IN THIS PORT THAT INCLUDES <openssl/>, and the only
// other one. `Tls.cpp` is the first. AGENTS.md used to confine the
// dependency exception to cryptographic TRANSPORT, which is why
// `Crypto.cpp` writes SHA-256 and HMAC-SHA256 out by hand beside a linked
// OpenSSL that has both; the rule now covers cryptography, because a
// block cipher protecting secrets AT REST has properties no known-answer
// vector can check - a table-driven AES passes every vector in the world
// and still hands its key to anyone who can time a cache. `make
// check-core` proves the CORE still includes no <openssl/> header at all.
//
// THE FILE FORMAT, which is the contract between the ports:
//
//   magic       4   'SKMV'
//   version     1   FORMAT
//   kdf         1   1 = PBKDF2-HMAC-SHA256
//   cipher      1   1 = AES-256-GCM
//   reserved    1   0
//   keycount    4   uint32
//   per key:
//     id        1 + bytes      the key id, PLAINTEXT
//     salt      1 + bytes
//     iters     4              PBKDF2 rounds for this key
//     ring      1 + iv, 4 + bytes    sealed under the passphrase
//     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
//   entrycount  4   uint32
//   per entry:
//     id        1 + bytes      the blinded lookup id
//     name      1 + iv, 4 + bytes    sealed under the vault's name key
//     value     1 + iv, 4 + bytes    sealed under that secret's own key
//
// Integers are big-endian and every length precedes its bytes, so the
// file is written with the same two primitives it is read with.
//
// NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed, and
// an entry is addressed by a blinded id derived from its own key, so a
// restricted key finds what it was granted without the file ever naming
// the rest. What the file does show anyone is the key ids and how many
// secrets there are.
//
// A port of typescript/plugins/minivault.ts, which is canonical. The
// bytes are pinned by the vaults in test/fixture rather than left to
// agreement between implementations.

namespace sekreto {

const char* const VAULT_MASTERKEY = "master";
const int VAULT_ITERATIONS = 210000;
const char* const VAULT_EXPORT = "vault";

namespace minivaultfile {

struct Sealed {
  std::vector<uint8_t> iv;
  std::vector<uint8_t> blob;
};

struct KeyRecord {
  std::string id;
  std::vector<uint8_t> salt;
  uint32_t iters = 0;
  Sealed ring;
  Sealed meta;
};

struct EntryRecord {
  std::vector<uint8_t> id;
  Sealed name;
  Sealed value;
};

struct Vault {
  std::vector<KeyRecord> keys;
  std::vector<EntryRecord> entries;
};

}  // namespace minivaultfile

namespace {

using minivaultfile::EntryRecord;
using minivaultfile::KeyRecord;
using minivaultfile::Sealed;

// --- the format ------------------------------------------------------

const char MAGIC[] = {'S', 'K', 'M', 'V'};
const uint8_t FORMAT = 1;
const uint8_t KDF_PBKDF2 = 1;
const uint8_t CIPHER_AESGCM = 1;

// AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
const size_t KEYLEN = 32;
const size_t IVLEN = 12;
const size_t TAGLEN = 16;
const size_t SALTLEN = 16;

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved: a restricted key's ring cannot be
// relabelled as the master's, and one secret's value cannot be served
// under a name it was never written for.
const char AAD_RING[] = "skmv1:ring:";
const char AAD_META[] = "skmv1:meta:";
const char AAD_NAME[] = "skmv1:name";
const char AAD_SECRET[] = "skmv1:secret:";

// Everything a master reaches is derived from the root key, so rotating
// is one new random value rather than a re-wrap of each part.
const char LABEL_NAMES[] = "skmv1:names";
const char LABEL_META[] = "skmv1:meta";
const char LABEL_ID[] = "skmv1:id";

// The largest key id the format can record.
//
// A length is written in ONE byte. A longer id wrapped that byte and the
// writer then appended the whole thing, so every field after it shifted:
// a grant with a 300-character id replaced a working vault with an
// unreadable one, and said nothing. Checked where an id is ACCEPTED, so
// the refusal names the id rather than the file.
const size_t IDMAX = 255;

[[noreturn]] void fail(const std::string& why) {
  throw SekretoError("sekreto: minivault: " + why);
}

std::string checkid(const std::string& id, const std::string& what) {
  if (id.empty()) fail(what);
  if (IDMAX < id.size()) {
    fail("key id is longer than " + std::to_string(IDMAX) + " bytes: " + id.substr(0, 32) + "...");
  }
  return id;
}

// --- bytes -----------------------------------------------------------

std::vector<uint8_t> bytesof(const std::string& text) {
  return std::vector<uint8_t>(text.begin(), text.end());
}

std::string textof(const std::vector<uint8_t>& raw) {
  return std::string(raw.begin(), raw.end());
}

// --- keys ------------------------------------------------------------

std::vector<uint8_t> mac(const std::vector<uint8_t>& key, const std::string& text) {
  std::vector<uint8_t> out(KEYLEN);
  unsigned int len = 0;

  HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()),
       reinterpret_cast<const unsigned char*>(text.data()), text.size(), out.data(), &len);

  return out;
}

// The key-encryption key a passphrase unwraps a ring with.
//
// PBKDF2 refuses a round count below one, which is what a damaged or
// hostile file records to make the derivation free; that is refused
// rather than turned into a key derived from nothing.
std::vector<uint8_t> kek(const std::string& passphrase, const std::vector<uint8_t>& salt,
                         uint32_t iters) {
  std::vector<uint8_t> out(KEYLEN);

  if (1 > iters) fail("unusable round count: " + std::to_string(iters));

  if (1 != PKCS5_PBKDF2_HMAC(passphrase.data(), static_cast<int>(passphrase.size()), salt.data(),
                             static_cast<int>(salt.size()), static_cast<int>(iters), EVP_sha256(),
                             static_cast<int>(KEYLEN), out.data())) {
    fail("cannot derive a key");
  }

  return out;
}

// The key one named secret's value is encrypted with.
//
// DERIVED, never stored, for a master: it holds the root key and so
// reaches every name, including ones written after it was made. A
// restricted key holds the derived keys it was granted and nothing that
// produces another, so every other name is ciphertext to it in exactly
// the way it is to a stranger.
std::vector<uint8_t> secretkey(const std::vector<uint8_t>& root, const std::string& name) {
  return mac(root, std::string(AAD_SECRET) + name);
}

// Where a secret lives in the file, derived from its own key so that
// finding it needs no plaintext name. One-way: an id yields nothing about
// the key that produced it.
std::vector<uint8_t> entryid(const std::vector<uint8_t>& key) { return mac(key, LABEL_ID); }

std::vector<uint8_t> randombytes(size_t len) {
  std::vector<uint8_t> out(len);
  if (1 != RAND_bytes(out.data(), static_cast<int>(len))) fail("no randomness available");
  return out;
}

// --- sealing ---------------------------------------------------------

bool sameseal(const Sealed& left, const Sealed& right) {
  return left.iv == right.iv && left.blob == right.blob;
}

// A scope guard, so that an OpenSSL context is released on every path -
// including the one where a refusal is thrown out of the middle.
class Cipher {
 public:
  Cipher() : ctx_(EVP_CIPHER_CTX_new()) {
    if (nullptr == ctx_) fail("cannot reach the cipher");
  }
  ~Cipher() { EVP_CIPHER_CTX_free(ctx_); }

  Cipher(const Cipher&) = delete;
  Cipher& operator=(const Cipher&) = delete;

  EVP_CIPHER_CTX* get() const { return ctx_; }

 private:
  EVP_CIPHER_CTX* ctx_;
};

// The tag rides at the END of the blob, which is where every other port's
// AEAD leaves it and therefore what the format records.
Sealed seal(const std::vector<uint8_t>& key, const std::vector<uint8_t>& plain,
            const std::string& aad) {
  if (KEYLEN != key.size()) fail("bad key");

  Sealed out;
  out.iv = randombytes(IVLEN);
  out.blob.resize(plain.size() + TAGLEN);

  Cipher cipher;
  int len = 0;
  const bool ok =
      1 == EVP_EncryptInit_ex(cipher.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) &&
      1 == EVP_CIPHER_CTX_ctrl(cipher.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(IVLEN),
                               nullptr) &&
      1 == EVP_EncryptInit_ex(cipher.get(), nullptr, nullptr, key.data(), out.iv.data()) &&
      1 == EVP_EncryptUpdate(cipher.get(), nullptr, &len,
                             reinterpret_cast<const unsigned char*>(aad.data()),
                             static_cast<int>(aad.size())) &&
      1 == EVP_EncryptUpdate(cipher.get(), out.blob.data(), &len, plain.data(),
                             static_cast<int>(plain.size())) &&
      1 == EVP_EncryptFinal_ex(cipher.get(), out.blob.data() + len, &len) &&
      1 == EVP_CIPHER_CTX_ctrl(cipher.get(), EVP_CTRL_GCM_GET_TAG, static_cast<int>(TAGLEN),
                               out.blob.data() + plain.size());

  if (!ok) fail("cannot seal");

  return out;
}

// The plaintext, or a refusal. A GCM tag that fails to verify is the only
// evidence there is, and it cannot tell a wrong passphrase from a damaged
// file, so `what` names the attempt and the message admits both.
std::vector<uint8_t> unseal(const std::vector<uint8_t>& key, const Sealed& box,
                            const std::string& aad, const std::string& what) {
  if (box.blob.size() < TAGLEN || IVLEN != box.iv.size()) fail(what + ": truncated");
  if (KEYLEN != key.size()) fail("bad key");

  const size_t cut = box.blob.size() - TAGLEN;
  std::vector<uint8_t> plain(cut);

  Cipher cipher;
  int len = 0;
  const bool ok =
      1 == EVP_DecryptInit_ex(cipher.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) &&
      1 == EVP_CIPHER_CTX_ctrl(cipher.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(IVLEN),
                               nullptr) &&
      1 == EVP_DecryptInit_ex(cipher.get(), nullptr, nullptr, key.data(), box.iv.data()) &&
      1 == EVP_DecryptUpdate(cipher.get(), nullptr, &len,
                             reinterpret_cast<const unsigned char*>(aad.data()),
                             static_cast<int>(aad.size())) &&
      1 == EVP_DecryptUpdate(cipher.get(), plain.data(), &len, box.blob.data(),
                             static_cast<int>(cut)) &&
      1 == EVP_CIPHER_CTX_ctrl(cipher.get(), EVP_CTRL_GCM_SET_TAG, static_cast<int>(TAGLEN),
                               const_cast<uint8_t*>(box.blob.data() + cut)) &&
      0 < EVP_DecryptFinal_ex(cipher.get(), plain.data() + len, &len);

  if (!ok) fail(what);

  return plain;
}

// --- base64 ----------------------------------------------------------

// Here rather than in `Httpjson.hpp`, which is where the decoder the HTTP
// stores share lives: including that header for a base64 alphabet would
// put the whole HTTP client into the link of a store that opens nothing,
// which is what `make lean` measures.
const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string b64(const std::vector<uint8_t>& raw) {
  std::string out;
  out.reserve((raw.size() + 2) / 3 * 4);

  for (size_t at = 0; at < raw.size(); at += 3) {
    const size_t left = raw.size() - at;
    unsigned long triple = static_cast<unsigned long>(raw[at]) << 16;
    if (1 < left) triple |= static_cast<unsigned long>(raw[at + 1]) << 8;
    if (2 < left) triple |= static_cast<unsigned long>(raw[at + 2]);

    out.push_back(B64[(triple >> 18) & 0x3f]);
    out.push_back(B64[(triple >> 12) & 0x3f]);
    out.push_back(1 < left ? B64[(triple >> 6) & 0x3f] : '=');
    out.push_back(2 < left ? B64[triple & 0x3f] : '=');
  }

  return out;
}

// STRICT. A lenient decoder hands back plausible bytes for a corrupted
// payload, and those bytes are then used AS A KEY.
std::vector<uint8_t> unb64(const std::string& text, const std::string& what) {
  if (text.empty() || 0 != text.size() % 4) fail("missing " + what);

  std::vector<uint8_t> out;
  int bits = 0;
  unsigned long held = 0;
  size_t pad = 0;

  for (size_t at = 0; at < text.size(); at++) {
    const char ch = text[at];

    if ('=' == ch) {
      pad++;
      if (2 < pad || text.size() - 2 > at + pad) fail("missing " + what);
      continue;
    }
    if (0 != pad) fail("missing " + what);

    const char* found = std::strchr(B64, ch);
    if (nullptr == found || '\0' == ch) fail("missing " + what);

    held = (held << 6) | static_cast<unsigned long>(found - B64);
    bits += 6;

    if (8 <= bits) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>((held >> bits) & 0xff));
    }
  }

  return out;
}

// --- reading and writing the file ------------------------------------

// A cursor, so that every length check is in one place: a truncated vault
// is refused rather than read as a short one.
class Reader {
 public:
  explicit Reader(const std::vector<uint8_t>& bytes) : bytes_(bytes) {}

  // Reads `length` bytes, or refuses.
  //
  // The bound is checked AGAINST WHAT IS LEFT, never by adding the length
  // to the cursor: a damaged vault can encode a length near 0xffffffff,
  // and the sum would wrap and hand back a slice the caller had no
  // business seeing.
  std::vector<uint8_t> take(uint64_t length) {
    if (static_cast<uint64_t>(bytes_.size() - at_) < length) fail("the vault file is truncated");
    const size_t from = at_;
    at_ += static_cast<size_t>(length);
    return std::vector<uint8_t>(bytes_.begin() + static_cast<long>(from),
                                bytes_.begin() + static_cast<long>(at_));
  }

  uint8_t u8() { return take(1)[0]; }

  uint32_t u32() {
    const std::vector<uint8_t> raw = take(4);
    return (static_cast<uint32_t>(raw[0]) << 24) | (static_cast<uint32_t>(raw[1]) << 16) |
           (static_cast<uint32_t>(raw[2]) << 8) | static_cast<uint32_t>(raw[3]);
  }

  std::vector<uint8_t> small() { return take(u8()); }
  std::vector<uint8_t> large() { return take(u32()); }

  Sealed sealed() {
    Sealed out;
    // The iv is read before the blob, and the two statements keep that
    // order; a brace initialiser would not, because the order of
    // evaluation of its elements is unspecified before C++17 for some
    // forms and easy to get wrong in any.
    out.iv = small();
    out.blob = large();
    return out;
  }

  size_t left() const { return bytes_.size() - at_; }
  bool done() const { return bytes_.size() == at_; }

 private:
  const std::vector<uint8_t>& bytes_;
  size_t at_ = 0;
};

minivaultfile::Vault readfile(const std::vector<uint8_t>& raw) {
  Reader read(raw);

  const std::vector<uint8_t> magic = read.take(4);
  if (0 != std::memcmp(MAGIC, magic.data(), 4)) fail("not a vault file");

  const uint8_t version = read.u8();
  if (FORMAT != version) fail("unsupported format version: " + std::to_string(version));

  const uint8_t kdf = read.u8();
  const uint8_t cipher = read.u8();
  if (KDF_PBKDF2 != kdf || CIPHER_AESGCM != cipher) {
    fail("unsupported kdf or cipher: " + std::to_string(kdf) + "/" + std::to_string(cipher));
  }
  read.u8();

  minivaultfile::Vault out;

  // A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a few
  // bytes, so a file claiming four billion of them is damaged; the loop
  // would find that out one truncation at a time, and `reserve` would not.
  uint32_t count = read.u32();
  if (read.left() < count) fail("the vault file is truncated");
  for (uint32_t index = 0; index < count; index++) {
    KeyRecord record;
    record.id = textof(read.small());
    record.salt = read.small();
    record.iters = read.u32();
    record.ring = read.sealed();
    record.meta = read.sealed();
    out.keys.push_back(std::move(record));
  }

  count = read.u32();
  if (read.left() < count) fail("the vault file is truncated");
  for (uint32_t index = 0; index < count; index++) {
    EntryRecord record;
    record.id = read.small();
    record.name = read.sealed();
    record.value = read.sealed();
    out.entries.push_back(std::move(record));
  }

  if (!read.done()) fail("the vault file has trailing bytes");

  return out;
}

class Writer {
 public:
  void u8(uint8_t value) { out.push_back(value); }

  void u32(uint32_t value) {
    u8(static_cast<uint8_t>((value >> 24) & 0xff));
    u8(static_cast<uint8_t>((value >> 16) & 0xff));
    u8(static_cast<uint8_t>((value >> 8) & 0xff));
    u8(static_cast<uint8_t>(value & 0xff));
  }

  void small(const std::vector<uint8_t>& value) {
    u8(static_cast<uint8_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
  }

  void large(const std::vector<uint8_t>& value) {
    u32(static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
  }

  void sealed(const Sealed& value) {
    small(value.iv);
    large(value.blob);
  }

  std::vector<uint8_t> out;
};

std::vector<uint8_t> writefile(const minivaultfile::Vault& file) {
  Writer write;

  write.out.insert(write.out.end(), MAGIC, MAGIC + 4);
  write.u8(FORMAT);
  write.u8(KDF_PBKDF2);
  write.u8(CIPHER_AESGCM);
  write.u8(0);

  write.u32(static_cast<uint32_t>(file.keys.size()));
  for (const KeyRecord& record : file.keys) {
    write.small(bytesof(record.id));
    write.small(record.salt);
    write.u32(record.iters);
    write.sealed(record.ring);
    write.sealed(record.meta);
  }

  // SORTED BY ID, which is a blinded value: the file therefore records
  // nothing about the order secrets were written in.
  std::vector<EntryRecord> entries = file.entries;
  std::sort(entries.begin(), entries.end(),
            [](const EntryRecord& left, const EntryRecord& right) { return left.id < right.id; });

  write.u32(static_cast<uint32_t>(entries.size()));
  for (const EntryRecord& record : entries) {
    write.small(record.id);
    write.sealed(record.name);
    write.sealed(record.value);
  }

  return write.out;
}

// --- the file on disk ------------------------------------------------

// Read as BINARY, byte for byte. `std::getline` and a text-mode stream
// would both lie about a vault, which is full of NULs and of bytes no
// encoding claims.
bool slurp(const std::string& path, std::vector<uint8_t>& out) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;

  out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());

  return true;
}

// Owner-only, because a vault file is the whole store, and EXCLUSIVE when
// asked: an exclusive create refuses an existing path and will not follow
// a symlink to make one, which is what makes the temporary below safe to
// name in a directory somebody else can write.
//
// `open` rather than `std::ofstream`, because the standard library has no
// way to ask for either. Errors come back as errno, so the caller can
// tell "already there" from "could not write".
int spill(const std::string& path, const std::vector<uint8_t>& raw, bool exclusive);

std::string jsonstring(const std::string& text) { return Json::quote(text); }

}  // namespace
}  // namespace sekreto

#include <fcntl.h>
#include <unistd.h>

namespace sekreto {
namespace {

int spill(const std::string& path, const std::vector<uint8_t>& raw, bool exclusive) {
  const int flags = O_WRONLY | O_CREAT | (exclusive ? O_EXCL : O_TRUNC);
  const int fd = ::open(path.c_str(), flags, 0600);

  if (0 > fd) return errno;

  size_t at = 0;
  while (at < raw.size()) {
    const ssize_t put = ::write(fd, raw.data() + at, raw.size() - at);
    if (0 > put) {
      if (EINTR == errno) continue;
      const int why = errno;
      ::close(fd);
      ::unlink(path.c_str());
      return why;
    }
    at += static_cast<size_t>(put);
  }

  if (0 != ::close(fd)) {
    const int why = errno;
    ::unlink(path.c_str());
    return why;
  }

  return 0;
}

std::string hex(const std::vector<uint8_t>& raw) {
  static const char digits[] = "0123456789abcdef";
  std::string out;

  for (uint8_t byte : raw) {
    out.push_back(digits[(byte >> 4) & 0x0f]);
    out.push_back(digits[byte & 0x0f]);
  }

  return out;
}

KeyRecord sealkey(const std::vector<uint8_t>& root, const std::string& id,
                  const std::string& passphrase, uint32_t iters, const std::string& ring,
                  const std::string& meta) {
  KeyRecord out;

  out.id = id;
  out.iters = iters;
  out.salt = randombytes(SALTLEN);
  out.ring = seal(kek(passphrase, out.salt, iters), bytesof(ring), std::string(AAD_RING) + id);
  out.meta = seal(mac(root, LABEL_META), bytesof(meta), std::string(AAD_META) + id);

  return out;
}

// The one key record a new or rotated vault starts with: a master holding
// the root, granted nothing because it needs nothing.
KeyRecord masterkey(const std::vector<uint8_t>& root, const std::string& id,
                    const std::string& passphrase, uint32_t iters) {
  const std::string ring = "{\"v\":" + std::to_string(FORMAT) + ",\"write\":true,\"root\":" +
                           jsonstring(b64(root)) + "}";
  const std::string meta =
      "{\"v\":" + std::to_string(FORMAT) + ",\"master\":true,\"write\":true,\"grants\":[]}";

  return sealkey(root, id, passphrase, iters, ring, meta);
}

// A JSON `true`, and nothing else. A missing field, a null and the string
// "true" are all false: the ring says what a key may do, and reading a
// damaged one permissively is how a read-only key becomes a writing one.
bool jsontrue(const Json& val) { return val.isbool() && val.boolval; }

// --- where the vaults live -------------------------------------------

// voxgig/plugin's values are numbers, strings, lists and maps - not
// pointers - so a definition exports the TICKET of what it made and
// `vaultof` looks it up, exactly as `providerplugin` exports a ticket for
// the provider.
//
// Unlike `providerslot`, this table is NOT emptied when the ticket is
// claimed: `vaultof` is called after construction, as often as an
// application likes. It holds WEAK pointers, so the vault's life is the
// provider's - a chain that has been destroyed leaves an expired ticket,
// and `vaultof` refuses instead of handing back a dangling handle. Expired
// entries are dropped when the next one is parked, so the table is bounded
// by the number of live vaults rather than by the number ever built.
//
// Process-global with a mutex, NOT thread_local like `providerslot`: that
// one is filled and claimed in one synchronous call on one thread, and
// this one is read by whatever thread later asks for the API.
struct Vaults {
  std::mutex lock;
  std::map<double, std::weak_ptr<MiniVault>> held;
  double next = 1;
};

Vaults& vaults() {
  static Vaults one;
  return one;
}

double parkvault(const std::shared_ptr<MiniVault>& vault) {
  Vaults& one = vaults();
  std::lock_guard<std::mutex> guard(one.lock);

  for (auto at = one.held.begin(); one.held.end() != at;) {
    at = at->second.expired() ? one.held.erase(at) : std::next(at);
  }

  const double ticket = one.next;
  one.next = ticket + 1;
  one.held[ticket] = vault;

  return ticket;
}

std::shared_ptr<MiniVault> vaultat(double ticket) {
  Vaults& one = vaults();
  std::lock_guard<std::mutex> guard(one.lock);

  auto at = one.held.find(ticket);
  if (one.held.end() == at) return nullptr;

  return at->second.lock();
}

// --- the provider ----------------------------------------------------

/// Reads a vault as one store in a chain.
///
/// The provider is the READ half and nothing more: a chain resolves
/// secrets, and writing one is a deliberate act with an API of its own.
/// That API is the same handle, reached with `vaultof` off a chain or
/// built directly with `openvault`.
class MiniVaultProvider : public Provider {
 public:
  explicit MiniVaultProvider(std::shared_ptr<MiniVault> vault) : vault_(std::move(vault)) {}

  std::optional<std::string> lookup(const std::string& name) override {
    return vault_->get(name);
  }

  std::string describe() const override { return "minivault:" + vault_->file(); }

  const std::shared_ptr<MiniVault>& vault() const { return vault_; }

 private:
  std::shared_ptr<MiniVault> vault_;
};

}  // namespace

// --- the vault -------------------------------------------------------

MiniVault::MiniVault(std::string file, std::string key, std::string passphrase, int iterations,
                     bool create)
    : file_(std::move(file)),
      key_(std::move(key)),
      passphrase_(std::move(passphrase)),
      iterations_(iterations),
      create_(create) {}

MiniVault::~MiniVault() = default;

void MiniVault::close() {
  opened_ = false;
  master_ = false;
  write_ = false;
  root_.clear();
  grants_.clear();
  ring_.reset();
}

minivaultfile::Vault MiniVault::fresh(const std::string& keyid, const std::string& passphrase,
                                      int iterations) {
  minivaultfile::Vault out;
  const std::vector<uint8_t> root = randombytes(KEYLEN);

  out.keys.push_back(masterkey(root, keyid, passphrase, static_cast<uint32_t>(iterations)));

  return out;
}

// Writes a vault file that is not there yet, and REFUSES one that is.
//
// Straight to the target under an exclusive create rather than through a
// temporary and a rename. A rename REPLACES its destination, so two
// processes creating the same vault both succeeded and the second
// discarded the first one's secrets; a stat beforehand only narrows that
// window. There is nothing to lose by writing the target directly here,
// because there is no file to damage: either this call creates it or it
// fails.
void MiniVault::putnew(const minivaultfile::Vault& file) {
  const int why = spill(file_, writefile(file), true);

  if (0 == why) return;
  if (EEXIST == why) fail("vault file already exists: " + file_);

  fail("cannot write " + file_);
}

// Replaces the file rather than editing it in place. The rename is what
// makes a concurrent reader see either the old file or the new one, so a
// write interrupted halfway leaves a vault rather than wreckage.
//
// THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
// anyone can predict, and an ordinary create FOLLOWS a symlink, so anyone
// who could write the vault's directory could point that name at another
// file and have the next save truncate it.
void MiniVault::save(const minivaultfile::Vault& file) {
  const std::string temp = file_ + "." + hex(randombytes(8)) + ".tmp";

  if (0 != spill(temp, writefile(file), true)) fail("cannot write " + file_);

  if (0 != std::rename(temp.c_str(), file_.c_str())) {
    // The vault is unchanged either way, and the write error is what the
    // caller needs to be told about.
    ::unlink(temp.c_str());
    fail("cannot write " + file_);
  }
}

// The file as this key sees it: parsed every call - it is different bytes
// every time - while the unwrapped ring is kept, because stretching a
// passphrase once per lookup is the cost that caching exists to avoid.
minivaultfile::Vault MiniVault::read() {
  std::vector<uint8_t> raw;

  if (!slurp(file_, raw)) {
    // A vault is configured deliberately, with a key. Its absence is a
    // broken deployment and never "no secrets here": answering a miss
    // would send the chain on to a weaker store, which is the failure
    // mode this library most has to avoid. `create` is the caller saying
    // the opposite, in writing.
    if (!create_) fail("no vault file: " + file_);

    putnew(fresh(key_, passphrase_, iterations_));

    if (!slurp(file_, raw)) fail("cannot read " + file_);
  }

  minivaultfile::Vault file = readfile(raw);

  const KeyRecord* record = nullptr;
  for (const KeyRecord& held : file.keys) {
    if (key_ == held.id) record = &held;
  }

  if (nullptr == record) {
    // REVOKED, or never there. Either way this handle is finished, and
    // dropping what it derived is what stops the next call answering from
    // memory.
    close();
    fail("no such key: " + key_);
  }

  // The file still holds this key, and holds the SAME ring: a key revoked
  // and re-granted under another passphrase is a different key wearing
  // the id, and re-deriving is what refuses it.
  if (opened_ && nullptr != ring_ && sameseal(*ring_, record->ring)) return file;
  close();

  const std::vector<uint8_t> plain =
      unseal(kek(passphrase_, record->salt, record->iters), record->ring,
             std::string(AAD_RING) + key_,
             "wrong passphrase for key " + key_ + ", or a damaged vault");

  Json held;
  if (!Json::parse(textof(plain), held) || !held.isobj()) {
    fail("unreadable key ring for " + key_);
  }

  const Json grants = held.get("grants");
  if (grants.isobj()) {
    for (const auto& pair : grants.objval) {
      std::string text;
      if (!pair.second.asstr(text)) fail("missing a granted key");
      grants_[pair.first] = unb64(text, "a granted key");
    }
  }

  std::string root;
  if (held.get("root").asstr(root)) {
    root_ = unb64(root, "the root key");
    master_ = true;
  }

  write_ = master_ || jsontrue(held.get("write"));
  ring_ = std::make_unique<Sealed>(record->ring);
  opened_ = true;

  return file;
}

// The root key, or a refusal naming what needed it.
std::vector<uint8_t> MiniVault::rootof(const std::string& what) {
  if (!master_) fail(what + " needs a master key, and " + key_ + " is restricted");
  return root_;
}

// The key for one name, or nothing when this key cannot reach it.
std::optional<std::vector<uint8_t>> MiniVault::keyfor(const std::string& name) {
  if (master_) return secretkey(root_, name);

  auto at = grants_.find(name);
  if (grants_.end() == at) return std::nullopt;

  return at->second;
}

VaultKeyInfo MiniVault::open() {
  read();

  std::vector<std::string> names;
  for (const auto& pair : grants_) names.push_back(pair.first);
  std::sort(names.begin(), names.end());

  return VaultKeyInfo(key_, master_, write_, names);
}

std::vector<std::string> MiniVault::list() {
  const minivaultfile::Vault file = read();
  std::vector<std::string> names;

  if (master_) {
    const std::vector<uint8_t> namekey = mac(root_, LABEL_NAMES);
    for (const EntryRecord& entry : file.entries) {
      names.push_back(
          textof(unseal(namekey, entry.name, AAD_NAME, "a secret name is damaged")));
    }
  } else {
    // A restricted key has no name key, so it reports the grants it can
    // actually find: the vault never tells it what else is there.
    for (const auto& pair : grants_) {
      const std::vector<uint8_t> want = entryid(pair.second);
      for (const EntryRecord& entry : file.entries) {
        if (want == entry.id) {
          names.push_back(pair.first);
          break;
        }
      }
    }
  }

  std::sort(names.begin(), names.end());

  return names;
}

std::optional<std::string> MiniVault::get(const std::string& name) {
  checkname(name);

  const minivaultfile::Vault file = read();

  // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
  // key that opened it, so a name this key cannot read is a name this
  // store does not hold for this caller - the same answer a stranger's
  // vault gives, and the one that makes a restricted key in front of a
  // broader store a workable chain.
  const std::optional<std::vector<uint8_t>> key = keyfor(name);
  if (!key.has_value()) return std::nullopt;

  const std::vector<uint8_t> want = entryid(*key);
  for (const EntryRecord& entry : file.entries) {
    if (want == entry.id) {
      return textof(unseal(*key, entry.value, std::string(AAD_SECRET) + name,
                           "the value of " + name + " is damaged"));
    }
  }

  return std::nullopt;
}

bool MiniVault::has(const std::string& name) { return get(name).has_value(); }

// THE LOCK EVERY HANDLE ON ONE FILE SHARES.
//
// Each MiniVault is its own object, so two handles on one path did not
// coordinate: both could finish `load()` before either saved, and the
// second rename then discarded the first one's change while reporting
// success. Keyed by the ABSOLUTE path, so two handles spelled differently
// still meet.
//
// A guarantee WITHIN one process, which is what DOCS.md promises and what
// the go port arranges the same way. Two processes still race, and the
// format's answer to that is the exclusive create and the atomic rename:
// a reader sees one whole vault or the other, never half of one.
//
// `recursive_mutex`, because it costs nothing and a mutating method that
// ever reached another would otherwise deadlock rather than misbehave.
std::recursive_mutex& lockfor(const std::string& file) {
  static std::mutex table;
  static std::map<std::string, std::unique_ptr<std::recursive_mutex>> held;

  std::string key = file;
  try {
    key = std::filesystem::absolute(file).lexically_normal().string();
  } catch (const std::exception&) {
    key = file;
  }

  std::lock_guard<std::mutex> guard(table);
  std::unique_ptr<std::recursive_mutex>& one = held[key];
  if (nullptr == one) {
    one = std::make_unique<std::recursive_mutex>();
  }

  return *one;
}

void MiniVault::set(const std::string& name, const std::string& value) {
  // Every write on this file, from any handle in this process,
  // serializes here; see lockfor.
  std::lock_guard<std::recursive_mutex> guard(lockfor(file_));

    checkname(name);

    minivaultfile::Vault file = read();

    if (!write_) fail("key " + key_ + " is read-only");

    const std::optional<std::vector<uint8_t>> key = keyfor(name);
    if (!key.has_value()) fail("key " + key_ + " was not granted " + name);

    const Sealed box = seal(*key, bytesof(value), std::string(AAD_SECRET) + name);
    const std::vector<uint8_t> id = entryid(*key);

    bool found = false;
    for (EntryRecord& entry : file.entries) {
      if (id == entry.id) {
        entry.value = box;
        found = true;
        break;
      }
    }

    if (!found) {
      // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
      // restricted key with `write` updates what it was granted and cannot
      // grow the vault, which is what "restricted" has to mean for the
      // grant list to stay the whole story.
      const std::vector<uint8_t> root = rootof("creating the secret " + name);

      EntryRecord made;
      made.id = id;
      made.name = seal(mac(root, LABEL_NAMES), bytesof(name), AAD_NAME);
      made.value = box;
      file.entries.push_back(std::move(made));
    }

    save(file);
}

void MiniVault::remove(const std::string& name) {
  // Every write on this file, from any handle in this process,
  // serializes here; see lockfor.
  std::lock_guard<std::recursive_mutex> guard(lockfor(file_));

    checkname(name);

    minivaultfile::Vault file = read();
    const std::vector<uint8_t> root = rootof("removing a secret");
    const std::vector<uint8_t> want = entryid(secretkey(root, name));

    std::vector<EntryRecord> kept;
    bool found = false;

    for (EntryRecord& entry : file.entries) {
      if (!found && want == entry.id) {
        found = true;
        continue;
      }
      kept.push_back(std::move(entry));
    }

    if (!found) fail("no such secret: " + name);

    file.entries = std::move(kept);

    save(file);
}

std::vector<VaultKeyInfo> MiniVault::keys() {
  const minivaultfile::Vault file = read();
  const std::vector<uint8_t> root = rootof("listing the keys");
  const std::vector<uint8_t> metakey = mac(root, LABEL_META);

  std::vector<VaultKeyInfo> out;

  for (const KeyRecord& record : file.keys) {
    bool master = false;
    bool write = false;
    std::vector<std::string> names;

    // A record written under a root key this one has replaced is still in
    // the file and still opens with its own passphrase, so it is reported
    // rather than hidden - with what it can do unknown.
    try {
      const std::vector<uint8_t> plain = unseal(
          metakey, record.meta, std::string(AAD_META) + record.id, "metadata");

      Json noted;
      if (!Json::parse(textof(plain), noted) || !noted.isobj()) {
        fail("unreadable metadata for key " + record.id);
      }

      master = jsontrue(noted.get("master"));
      write = jsontrue(noted.get("write"));

      const Json grants = noted.get("grants");
      if (grants.isarr()) {
        for (const Json& item : grants.arrval) {
          std::string name;
          if (item.asstr(name)) names.push_back(name);
        }
      }
      std::sort(names.begin(), names.end());
    } catch (const SekretoError&) {
      // Left as it started: unknown.
    }

    out.emplace_back(record.id, master, write, names);
  }

  return out;
}

void MiniVault::grant(const GrantSpec& spec) {
  // Every write on this file, from any handle in this process,
  // serializes here; see lockfor.
  std::lock_guard<std::recursive_mutex> guard(lockfor(file_));

    minivaultfile::Vault file = read();
    const std::vector<uint8_t> root = rootof("granting a key");

    checkid(spec.key, "a grant needs a key id");
    if (spec.passphrase.empty()) fail("a grant needs a passphrase");

    for (const KeyRecord& record : file.keys) {
      if (spec.key == record.id) fail("key already exists: " + spec.key);
    }

    std::vector<std::string> names = spec.names;
    std::sort(names.begin(), names.end());

    // Written out rather than built as a Json and stringified, because
    // `false` and `true` must be literals and the two documents are three
    // fields each. Every string goes through the JSON quoter: a name is
    // `[a-z0-9_.]` by the time it reaches here, but "this cannot contain a
    // quote" is exactly the assumption that stops being true when a rule
    // moves.
    std::string ring = "{\"v\":" + std::to_string(FORMAT) +
                       ",\"write\":" + (spec.write ? "true" : "false") + ",\"grants\":{";
    std::string meta = "{\"v\":" + std::to_string(FORMAT) + ",\"master\":false,\"write\":" +
                       (spec.write ? "true" : "false") + ",\"grants\":[";

    for (size_t at = 0; at < names.size(); at++) {
      checkname(names[at]);

      if (0 < at) {
        ring += ",";
        meta += ",";
      }

      ring += jsonstring(names[at]) + ":" + jsonstring(b64(secretkey(root, names[at])));
      meta += jsonstring(names[at]);
    }

    ring += "}}";
    meta += "]}";

    file.keys.push_back(sealkey(root, spec.key, spec.passphrase,
                                static_cast<uint32_t>(0 < spec.iterations ? spec.iterations
                                                                          : iterations_),
                                ring, meta));

    save(file);
}

void MiniVault::revoke(const std::string& key) {
  // Every write on this file, from any handle in this process,
  // serializes here; see lockfor.
  std::lock_guard<std::recursive_mutex> guard(lockfor(file_));

    minivaultfile::Vault file = read();
    rootof("revoking a key");

    if (key == key_) fail("a key cannot revoke itself: " + key);

    bool found = false;
    std::vector<KeyRecord> kept;

    for (KeyRecord& record : file.keys) {
      if (key == record.id) {
        found = true;
        continue;
      }
      kept.push_back(std::move(record));
    }

    if (!found) fail("no such key: " + key);

    file.keys = std::move(kept);

    save(file);
}

void MiniVault::rotate() {
  // Every write on this file, from any handle in this process,
  // serializes here; see lockfor.
  std::lock_guard<std::recursive_mutex> guard(lockfor(file_));

    const minivaultfile::Vault file = read();
    const std::vector<uint8_t> oldroot = rootof("rotating the vault");

    uint32_t iters = 0;
    for (const KeyRecord& record : file.keys) {
      if (key_ == record.id) iters = record.iters;
    }

    // Read everything out under the old root before anything changes: once
    // the root is replaced the old derived keys are unreachable.
    const std::vector<uint8_t> oldnamekey = mac(oldroot, LABEL_NAMES);
    std::vector<std::pair<std::string, std::string>> held;

    for (const EntryRecord& entry : file.entries) {
      const std::string name =
          textof(unseal(oldnamekey, entry.name, AAD_NAME, "a secret name is damaged"));
      const std::string value =
          textof(unseal(secretkey(oldroot, name), entry.value, std::string(AAD_SECRET) + name,
                        "the value of " + name + " is damaged"));
      held.emplace_back(name, value);
    }

    const std::vector<uint8_t> root = randombytes(KEYLEN);
    const std::vector<uint8_t> namekey = mac(root, LABEL_NAMES);

    minivaultfile::Vault made;

    for (const auto& secret : held) {
      const std::vector<uint8_t> key = secretkey(root, secret.first);

      EntryRecord entry;
      entry.id = entryid(key);
      entry.name = seal(namekey, bytesof(secret.first), AAD_NAME);
      entry.value = seal(key, bytesof(secret.second), std::string(AAD_SECRET) + secret.first);
      made.entries.push_back(std::move(entry));
    }

    made.keys.push_back(masterkey(root, key_, passphrase_, iters));

    // SAVE FIRST, adopt second. A handle holding the new root over a file
    // that still holds the old one reads nothing and says the vault is
    // damaged, which is the wrong story about a failed write.
    save(made);

    // Dropped rather than replaced: the next call re-derives from the file
    // this one just wrote, which is the same rule every other change
    // follows.
    close();
}

// --- opening and creating --------------------------------------------

std::shared_ptr<MiniVault> openvault(const VaultOptions& options) {
  if (options.file.empty()) fail("a vault needs a file");
  if (options.passphrase.empty()) fail("a vault needs a passphrase");

  const std::string key = options.key.empty() ? VAULT_MASTERKEY : options.key;
  checkid(key, "a vault needs a key id");

  return std::make_shared<MiniVault>(options.file, key, options.passphrase,
                                     0 < options.iterations ? options.iterations
                                                            : VAULT_ITERATIONS,
                                     options.create);
}

std::shared_ptr<MiniVault> createvault(const VaultOptions& options) {
  std::shared_ptr<MiniVault> vault = openvault(options);

  // No stat first: the check and the write would be two steps, and
  // `putnew` refuses an existing file in ONE, which is what makes two
  // processes racing to create a vault leave one vault.
  VaultOptions made = options;
  made.key = vault->key();

  const std::vector<uint8_t> root = randombytes(KEYLEN);
  minivaultfile::Vault file;
  file.keys.push_back(masterkey(root, vault->key(), options.passphrase,
                                static_cast<uint32_t>(0 < options.iterations ? options.iterations
                                                                             : VAULT_ITERATIONS)));

  const int why = spill(options.file, writefile(file), true);
  if (EEXIST == why) fail("vault file already exists: " + options.file);
  if (0 != why) fail("cannot write " + options.file);

  return vault;
}

// --- the definition --------------------------------------------------

// Written out rather than built by `providerplugin`, because this
// definition publishes TWO exports: `provider`, the read half every kind
// publishes, and `vault`, the programmatic API. voxgig/plugin's exports
// are how a definition offers an application more than the host's own
// vocabulary, and a store that can only be read is half a vault.
//
// The `sekreto_error` wrapping is what `providerplugin` would have done:
// plugin wraps a code-less error raised in `define` as
// `plugin_define_failed` and keeps one that already carries a code, so a
// refusal of this provider's own configuration travels under
// `sekreto_error` and comes back out of the host as itself.
Definition minivault() {
  auto def = std::make_shared<plugin::Definition>();

  def->name = "minivault";
  def->define = [](plugin::Inst& inst) {
    std::shared_ptr<MiniVault> vault;

    try {
      const ProviderSpec spec = specof(inst.options());

      VaultOptions options;
      options.file = spec.file;
      options.key = spec.vaultkey;
      options.passphrase = spec.passphrase;
      options.iterations = spec.iterations.value_or(0);
      options.create = spec.create;

      // Configuration is refused HERE, so a mistyped chain fails at
      // construction. Reaching the file is not configuration: the handle
      // is lazy, and nothing is read or stretched until a lookup.
      vault = openvault(options);
    } catch (const SekretoError& err) {
      plugin::fail(ERROR_CODE, err.what(),
                   plugin::details2("ref", plugin::vstr(inst.ref()), "cause",
                                    plugin::vstr(err.what())));
    }

    inst.exportvalue(PROVIDER_EXPORT,
                     plugin::vnum(providerslot(std::make_shared<MiniVaultProvider>(vault))));
    inst.exportvalue(VAULT_EXPORT, plugin::vnum(parkvault(vault)));
  };

  return def;
}

std::shared_ptr<MiniVault> vaultof(const Sekreto& secrets, const std::string& store) {
  if (store.empty()) {
    const plugin::V ticket =
        secrets.host().exports(std::string("minivault/") + VAULT_EXPORT);
    std::shared_ptr<MiniVault> vault =
        plugin::isnum(ticket) ? vaultat(plugin::asnum(ticket)) : nullptr;

    if (nullptr == vault) fail("no minivault store in this chain");

    return vault;
  }

  // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
  // `host.exports` falls back to the alias when the exact ref misses, so
  // asking for `minivault` in a chain whose only vault is named `app`
  // used to hand back the `app` vault - and then write to it. Naming a
  // store that is not there throws, which is the rule the whole library
  // follows: `tryget` already means "may not have it", so it cannot also
  // mean "may not exist".
  const std::string missing = "no minivault store named " + store + " in this chain";
  const std::string ref = "minivault" == store ? "minivault" : "minivault$" + store;

  if (nullptr == secrets.host().instance(ref)) fail(missing);

  const plugin::V ticket = secrets.host().exports(ref + "/" + VAULT_EXPORT);
  std::shared_ptr<MiniVault> vault =
      plugin::isnum(ticket) ? vaultat(plugin::asnum(ticket)) : nullptr;

  if (nullptr == vault) fail(missing);

  return vault;
}

}  // namespace sekreto
