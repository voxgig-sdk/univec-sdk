// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (c/plugins/minivault.c)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* A mini vault: every secret a project owns, encrypted, in ONE FILE.
 *
 * The store to reach for before there is a vault server. There is
 * nothing to run and nothing to reach over a socket - the whole store is
 * a single binary file - and the same chain that reads it in development
 * reads HashiCorp or AWS in production by changing config, which is the
 * reason sekreto exists.
 *
 * It is a plugin rather than a built-in kind because it needs crypto,
 * which is the line the four built-ins stay behind.
 *
 * THE SECOND OBJECT IN THIS LIBRARY THAT NAMES OpenSSL, and the only
 * other one. `tls.c` is the first. AGENTS.md used to confine the
 * dependency exception to cryptographic TRANSPORT, which is why
 * `sha256.c` writes SHA-256 and HMAC-SHA256 out by hand beside a linked
 * libcrypto that has both; the rule now covers cryptography, because a
 * block cipher protecting secrets AT REST has properties no known-answer
 * vector can check - a table-driven AES passes every vector in the world
 * and still hands its key to anyone who can time a cache. `make
 * check-tls` reads the archives and fails if any THIRD object reaches
 * for it.
 *
 * THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
 * every name and mints restricted keys. A restricted key reads the names
 * it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
 * cryptography rather than a check this code performs, so a copy of the
 * file plus a restricted passphrase yields exactly what was granted and
 * nothing else. What that does and does not protect is set out in
 * DOCS.md under "What the mini vault protects".
 *
 * THE FILE FORMAT, which is the contract between the ports:
 *
 *   magic       4   'SKMV'
 *   version     1   FORMAT
 *   kdf         1   1 = PBKDF2-HMAC-SHA256
 *   cipher      1   1 = AES-256-GCM
 *   reserved    1   0
 *   keycount    4   uint32
 *   per key:
 *     id        1 + bytes      the key id, PLAINTEXT
 *     salt      1 + bytes
 *     iters     4              PBKDF2 rounds for this key
 *     ring      1 + iv, 4 + bytes    sealed under the passphrase
 *     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
 *   entrycount  4   uint32
 *   per entry:
 *     id        1 + bytes      the blinded lookup id
 *     name      1 + iv, 4 + bytes    sealed under the vault's name key
 *     value     1 + iv, 4 + bytes    sealed under that secret's own key
 *
 * Integers are big-endian and every length precedes its bytes, so the
 * file is written with the same two primitives it is read with.
 *
 * NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed,
 * and an entry is addressed by a blinded id derived from its own key, so
 * a restricted key finds what it was granted without the file ever
 * naming the rest. What the file does show anyone is the key ids and how
 * many secrets there are.
 *
 * A port of typescript/plugins/minivault.ts, which is canonical. The
 * bytes are pinned by the vaults in ../../test/fixture rather than left
 * to agreement between implementations.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

#include "support.h"

/* ---- the format ---------------------------------------------------- */

#define MV_MAGIC "SKMV"
#define MV_FORMAT 1
#define MV_KDF_PBKDF2 1
#define MV_CIPHER_AESGCM 1

/* AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. */
#define MV_KEYLEN 32
#define MV_IVLEN 12
#define MV_TAGLEN 16
#define MV_SALTLEN 16

/* Additional authenticated data. Every blob is bound to its PLACE in the
 * file, so no ciphertext can be moved: a restricted key's ring cannot be
 * relabelled as the master's, and one secret's value cannot be served
 * under a name it was never written for. */
#define MV_AAD_RING "skmv1:ring:"
#define MV_AAD_META "skmv1:meta:"
#define MV_AAD_NAME "skmv1:name"
#define MV_AAD_SECRET "skmv1:secret:"

/* Everything a master reaches is derived from the root key, so rotating
 * is one new random value rather than a re-wrap of each part. */
#define MV_LABEL_NAMES "skmv1:names"
#define MV_LABEL_META "skmv1:meta"
#define MV_LABEL_ID "skmv1:id"

/* The largest key id the format can record.
 *
 * A length is written in ONE byte. A longer id wrapped that byte and the
 * writer then appended the whole thing, so every field after it shifted:
 * a grant with a 300-character id replaced a working vault with an
 * unreadable one, and said nothing. Checked where an id is ACCEPTED, so
 * the refusal names the id rather than the file. */
#define MV_IDMAX 255

static sek_err mvfail(sek_pool *pool, const char *fmt, ...);

static sek_err mvfail(sek_pool *pool, const char *fmt, ...) {
  va_list args;
  char body[512];

  va_start(args, fmt);
  vsnprintf(body, sizeof(body), fmt, args);
  va_end(args);

  return sek_fmt(pool, "sekreto: minivault: %s", body);
}

static sek_err mvcheckid(sek_pool *pool, const char *id, const char *what) {
  size_t len = sek_empty(id) ? 0 : strlen(id);

  if (0 == len) {
    return mvfail(pool, "%s", what);
  }
  if (MV_IDMAX < len) {
    return mvfail(pool, "key id is longer than %d bytes: %.32s...", MV_IDMAX, id);
  }

  return NULL;
}

/* ---- bytes --------------------------------------------------------- */

/* A length-carrying byte string, because a vault holds NULs everywhere
 * and a `char *` would end at the first one. */
typedef struct {
  unsigned char *data;
  size_t len;
} mvbytes;

static mvbytes mvmake(sek_pool *pool, size_t len) {
  mvbytes out;
  out.data = (unsigned char *)sek_alloc(pool, 0 == len ? 1 : len);
  out.len = len;
  return out;
}

static mvbytes mvcopy(sek_pool *pool, const unsigned char *from, size_t len) {
  mvbytes out = mvmake(pool, len);
  if (0 < len) {
    memcpy(out.data, from, len);
  }
  return out;
}

static mvbytes mvoftext(sek_pool *pool, const char *text) {
  return mvcopy(pool, (const unsigned char *)text, strlen(text));
}

/* The bytes as a C string. Every plaintext this is used on is a secret
 * name or a secret value, and both are text by the library's own rules. */
static char *mvtext(sek_pool *pool, mvbytes raw) {
  char *out = (char *)sek_alloc(pool, raw.len + 1);
  memcpy(out, raw.data, raw.len);
  out[raw.len] = '\0';
  return out;
}

static int mvsame(mvbytes left, mvbytes right) {
  return left.len == right.len && 0 == memcmp(left.data, right.data, left.len);
}

/* ---- keys ---------------------------------------------------------- */

static mvbytes mvmac(sek_pool *pool, mvbytes key, const char *text) {
  mvbytes out = mvmake(pool, MV_KEYLEN);
  unsigned int len = 0;

  HMAC(EVP_sha256(), key.data, (int)key.len, (const unsigned char *)text, strlen(text), out.data,
       &len);

  return out;
}

/* The key-encryption key a passphrase unwraps a ring with.
 *
 * PBKDF2 refuses a round count below one, which is what a damaged or
 * hostile file records to make the derivation free; that comes back as a
 * refusal rather than as a key derived from nothing. */
static sek_err mvkek(sek_pool *pool, const char *passphrase, mvbytes salt, int iters,
                     mvbytes *out) {
  *out = mvmake(pool, MV_KEYLEN);

  if (1 > iters) {
    return mvfail(pool, "unusable round count: %d", iters);
  }

  if (1 != PKCS5_PBKDF2_HMAC(passphrase, (int)strlen(passphrase), salt.data, (int)salt.len, iters,
                             EVP_sha256(), MV_KEYLEN, out->data)) {
    return mvfail(pool, "cannot derive a key");
  }

  return NULL;
}

/* The key one named secret's value is encrypted with.
 *
 * DERIVED, never stored, for a master: it holds the root key and so
 * reaches every name, including ones written after it was made. A
 * restricted key holds the derived keys it was granted and nothing that
 * produces another, so every other name is ciphertext to it in exactly
 * the way it is to a stranger. */
static mvbytes mvsecretkey(sek_pool *pool, mvbytes root, const char *name) {
  return mvmac(pool, root, sek_fmt(pool, "%s%s", MV_AAD_SECRET, name));
}

/* Where a secret lives in the file, derived from its own key so that
 * finding it needs no plaintext name. One-way: an id yields nothing
 * about the key that produced it. */
static mvbytes mventryid(sek_pool *pool, mvbytes key) {
  return mvmac(pool, key, MV_LABEL_ID);
}

/* Hex, here rather than `sek_hex`: that one lives in `sha256.c` with the
 * SigV4 digest, and naming it would pull the digest into every binary
 * that links this plugin - which is the boundary `make check-core`
 * measures. Eight random bytes in a temporary file name is the only use
 * it has. */
static char *mvhex(sek_pool *pool, mvbytes raw) {
  static const char digits[] = "0123456789abcdef";
  char *out = (char *)sek_alloc(pool, raw.len * 2 + 1);
  size_t at;

  for (at = 0; at < raw.len; at++) {
    out[at * 2] = digits[(raw.data[at] >> 4) & 0x0f];
    out[at * 2 + 1] = digits[raw.data[at] & 0x0f];
  }
  out[raw.len * 2] = '\0';

  return out;
}

/* A JSON `true`, and nothing else. A missing field, a null and the
 * string "true" are all false: the ring says what a key may do, and
 * reading a damaged one permissively is how a read-only key becomes a
 * writing one. */
static int mvjsonbool(const sek_json *val) {
  return NULL != val && SEK_JSON_BOOL == val->type && 0 != val->boolval;
}

static sek_err mvrandom(sek_pool *pool, size_t len, mvbytes *out) {
  *out = mvmake(pool, len);

  if (1 != RAND_bytes(out->data, (int)len)) {
    return mvfail(pool, "no randomness available");
  }

  return NULL;
}

/* ---- sealing ------------------------------------------------------- */

typedef struct {
  mvbytes iv;
  mvbytes blob;
} mvsealed;

static int mvsameseal(mvsealed left, mvsealed right) {
  return mvsame(left.iv, right.iv) && mvsame(left.blob, right.blob);
}

/* The tag rides at the END of the blob, which is where every other
 * port's AEAD leaves it and therefore what the format records. */
static sek_err mvseal(sek_pool *pool, mvbytes key, mvbytes plain, const char *aad, mvsealed *out) {
  EVP_CIPHER_CTX *ctx = NULL;
  sek_err err = mvrandom(pool, MV_IVLEN, &out->iv);
  int len = 0;
  int ok = 0;

  if (NULL != err) {
    return err;
  }
  if (MV_KEYLEN != key.len) {
    return mvfail(pool, "bad key");
  }

  out->blob = mvmake(pool, plain.len + MV_TAGLEN);

  ctx = EVP_CIPHER_CTX_new();
  if (NULL == ctx) {
    return mvfail(pool, "cannot seal");
  }

  ok = 1 == EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, MV_IVLEN, NULL) &&
       1 == EVP_EncryptInit_ex(ctx, NULL, NULL, key.data, out->iv.data) &&
       1 == EVP_EncryptUpdate(ctx, NULL, &len, (const unsigned char *)aad, (int)strlen(aad)) &&
       1 == EVP_EncryptUpdate(ctx, out->blob.data, &len, plain.data, (int)plain.len) &&
       1 == EVP_EncryptFinal_ex(ctx, out->blob.data + len, &len) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, MV_TAGLEN,
                                out->blob.data + plain.len);

  EVP_CIPHER_CTX_free(ctx);

  return ok ? NULL : mvfail(pool, "cannot seal");
}

/* The plaintext, or a refusal. A GCM tag that fails to verify is the
 * only evidence there is, and it cannot tell a wrong passphrase from a
 * damaged file, so `what` names the attempt and the message admits both. */
static sek_err mvunseal(sek_pool *pool, mvbytes key, mvsealed box, const char *aad,
                        const char *what, mvbytes *out) {
  EVP_CIPHER_CTX *ctx = NULL;
  size_t cut;
  int len = 0;
  int ok = 0;

  if (box.blob.len < MV_TAGLEN || MV_IVLEN != box.iv.len) {
    return mvfail(pool, "%s: truncated", what);
  }
  if (MV_KEYLEN != key.len) {
    return mvfail(pool, "bad key");
  }

  cut = box.blob.len - MV_TAGLEN;
  *out = mvmake(pool, cut);

  ctx = EVP_CIPHER_CTX_new();
  if (NULL == ctx) {
    return mvfail(pool, "%s", what);
  }

  ok = 1 == EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, MV_IVLEN, NULL) &&
       1 == EVP_DecryptInit_ex(ctx, NULL, NULL, key.data, box.iv.data) &&
       1 == EVP_DecryptUpdate(ctx, NULL, &len, (const unsigned char *)aad, (int)strlen(aad)) &&
       1 == EVP_DecryptUpdate(ctx, out->data, &len, box.blob.data, (int)cut) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, MV_TAGLEN,
                                (void *)(box.blob.data + cut)) &&
       0 < EVP_DecryptFinal_ex(ctx, out->data + len, &len);

  EVP_CIPHER_CTX_free(ctx);

  return ok ? NULL : mvfail(pool, "%s", what);
}

/* ---- base64 -------------------------------------------------------- */

static const char MV_B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Here rather than in `encode.c`, so that a link of this plugin pulls no
 * percent-encoder and a link of an HTTP store pulls no base64 ENCODER.
 * `sek_unbase64` stays where it is: four HTTP stores need it and this
 * plugin needs a decoder too, so the decoder is shared and the encoder,
 * which only this plugin has ever needed, is not. */
static char *mvb64(sek_pool *pool, mvbytes raw) {
  size_t groups = (raw.len + 2) / 3;
  char *out = (char *)sek_alloc(pool, groups * 4 + 1);
  size_t at = 0;
  size_t index;

  for (index = 0; index < raw.len; index += 3) {
    unsigned long triple = (unsigned long)raw.data[index] << 16;
    size_t left = raw.len - index;

    if (1 < left) {
      triple |= (unsigned long)raw.data[index + 1] << 8;
    }
    if (2 < left) {
      triple |= (unsigned long)raw.data[index + 2];
    }

    out[at++] = MV_B64[(triple >> 18) & 0x3f];
    out[at++] = MV_B64[(triple >> 12) & 0x3f];
    out[at++] = 1 < left ? MV_B64[(triple >> 6) & 0x3f] : '=';
    out[at++] = 2 < left ? MV_B64[triple & 0x3f] : '=';
  }

  out[at] = '\0';

  return out;
}

static sek_err mvunb64(sek_pool *pool, const char *text, const char *what, mvbytes *out) {
  size_t len = 0;
  unsigned char *raw = sek_empty(text) ? NULL : sek_unbase64(pool, text, &len);

  out->data = NULL;
  out->len = 0;

  if (NULL == raw) {
    return mvfail(pool, "missing %s", what);
  }

  out->data = raw;
  out->len = len;

  return NULL;
}

/* ---- the file ------------------------------------------------------ */

typedef struct {
  const char *id;
  mvbytes salt;
  int iters;
  mvsealed ring;
  mvsealed meta;
} mvkeyrecord;

typedef struct {
  mvbytes id;
  mvsealed name;
  mvsealed value;
} mventryrecord;

typedef struct {
  sek_pool *pool;
  mvkeyrecord *keys;
  size_t keylen;
  size_t keycap;
  mventryrecord *entries;
  size_t entrylen;
  size_t entrycap;
} mvfile;

static void mvaddkey(mvfile *file, mvkeyrecord record) {
  if (file->keylen == file->keycap) {
    size_t cap = 0 == file->keycap ? 4 : file->keycap * 2;
    mvkeyrecord *bigger = (mvkeyrecord *)sek_alloc(file->pool, cap * sizeof(mvkeyrecord));
    if (0 < file->keylen) {
      memcpy(bigger, file->keys, file->keylen * sizeof(mvkeyrecord));
    }
    file->keys = bigger;
    file->keycap = cap;
  }
  file->keys[file->keylen++] = record;
}

static void mvaddentry(mvfile *file, mventryrecord record) {
  if (file->entrylen == file->entrycap) {
    size_t cap = 0 == file->entrycap ? 8 : file->entrycap * 2;
    mventryrecord *bigger = (mventryrecord *)sek_alloc(file->pool, cap * sizeof(mventryrecord));
    if (0 < file->entrylen) {
      memcpy(bigger, file->entries, file->entrylen * sizeof(mventryrecord));
    }
    file->entries = bigger;
    file->entrycap = cap;
  }
  file->entries[file->entrylen++] = record;
}

static mvkeyrecord *mvkeyof(mvfile *file, const char *id) {
  size_t at;
  for (at = 0; at < file->keylen; at++) {
    if (0 == strcmp(id, file->keys[at].id)) {
      return &file->keys[at];
    }
  }
  return NULL;
}

static mventryrecord *mventryof(mvfile *file, mvbytes id) {
  size_t at;
  for (at = 0; at < file->entrylen; at++) {
    if (mvsame(id, file->entries[at].id)) {
      return &file->entries[at];
    }
  }
  return NULL;
}

/* A cursor, so that every length check is in one place: a truncated
 * vault is refused rather than read as a short one. */
typedef struct {
  const unsigned char *bytes;
  size_t len;
  size_t at;
  int bad;
} mvreader;

/* Reads `length` bytes, or records the refusal.
 *
 * The bound is checked AGAINST WHAT IS LEFT, never by adding the length
 * to `at`: a damaged vault can encode a length near 0xffffffff, and the
 * sum would wrap on a 32-bit size_t and hand back a slice the caller had
 * no business seeing. */
static mvbytes mvtake(mvreader *read, unsigned long length) {
  mvbytes out;

  out.data = NULL;
  out.len = 0;

  if (read->bad) {
    return out;
  }
  if ((unsigned long)(read->len - read->at) < length) {
    read->bad = 1;
    return out;
  }

  out.data = (unsigned char *)read->bytes + read->at;
  out.len = (size_t)length;
  read->at += (size_t)length;

  return out;
}

static unsigned int mvu8(mvreader *read) {
  mvbytes out = mvtake(read, 1);
  return 0 == out.len ? 0 : out.data[0];
}

static unsigned long mvu32(mvreader *read) {
  mvbytes out = mvtake(read, 4);
  if (4 != out.len) {
    return 0;
  }
  return ((unsigned long)out.data[0] << 24) | ((unsigned long)out.data[1] << 16) |
         ((unsigned long)out.data[2] << 8) | (unsigned long)out.data[3];
}

static mvbytes mvsmall(mvreader *read) { return mvtake(read, mvu8(read)); }
static mvbytes mvlarge(mvreader *read) { return mvtake(read, mvu32(read)); }

static mvsealed mvreadsealed(mvreader *read) {
  mvsealed out;
  /* The iv is read before the blob, and the two statements keep that
   * order; a struct initialiser would not, because C leaves the order of
   * evaluation of its members unspecified. */
  out.iv = mvsmall(read);
  out.blob = mvlarge(read);
  return out;
}

static sek_err mvreadfile(sek_pool *pool, mvbytes raw, mvfile *out) {
  mvreader read;
  mvbytes magic;
  unsigned int version, kdf, cipher;
  unsigned long count;
  unsigned long index;

  memset(&read, 0, sizeof(read));
  read.bytes = raw.data;
  read.len = raw.len;

  memset(out, 0, sizeof(*out));
  out->pool = pool;

  magic = mvtake(&read, 4);
  if (4 != magic.len) {
    return mvfail(pool, "the vault file is truncated");
  }
  if (0 != memcmp(MV_MAGIC, magic.data, 4)) {
    return mvfail(pool, "not a vault file");
  }

  version = mvu8(&read);
  if (read.bad) {
    return mvfail(pool, "the vault file is truncated");
  }
  if (MV_FORMAT != version) {
    return mvfail(pool, "unsupported format version: %u", version);
  }

  kdf = mvu8(&read);
  cipher = mvu8(&read);
  if (read.bad) {
    return mvfail(pool, "the vault file is truncated");
  }
  if (MV_KDF_PBKDF2 != kdf || MV_CIPHER_AESGCM != cipher) {
    return mvfail(pool, "unsupported kdf or cipher: %u/%u", kdf, cipher);
  }
  mvu8(&read);

  /* A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
   * few bytes, so a file claiming four billion of them is damaged; the
   * loop would find that out one truncation at a time, and this never
   * allocates per claimed record before the bytes are there. */
  count = mvu32(&read);
  if ((unsigned long)(read.len - read.at) < count) {
    return mvfail(pool, "the vault file is truncated");
  }
  for (index = 0; index < count && !read.bad; index++) {
    mvkeyrecord record;
    record.id = mvtext(pool, mvsmall(&read));
    record.salt = mvsmall(&read);
    record.iters = (int)mvu32(&read);
    record.ring = mvreadsealed(&read);
    record.meta = mvreadsealed(&read);
    mvaddkey(out, record);
  }

  count = mvu32(&read);
  if ((unsigned long)(read.len - read.at) < count) {
    return mvfail(pool, "the vault file is truncated");
  }
  for (index = 0; index < count && !read.bad; index++) {
    mventryrecord record;
    record.id = mvsmall(&read);
    record.name = mvreadsealed(&read);
    record.value = mvreadsealed(&read);
    mvaddentry(out, record);
  }

  if (read.bad) {
    return mvfail(pool, "the vault file is truncated");
  }
  if (read.at != read.len) {
    return mvfail(pool, "the vault file has trailing bytes");
  }

  return NULL;
}

static void mvwriteu8(sek_buf *buf, unsigned int value) {
  sek_buf_addch(buf, (char)(value & 0xff));
}

static void mvwriteu32(sek_buf *buf, unsigned long value) {
  mvwriteu8(buf, (unsigned int)((value >> 24) & 0xff));
  mvwriteu8(buf, (unsigned int)((value >> 16) & 0xff));
  mvwriteu8(buf, (unsigned int)((value >> 8) & 0xff));
  mvwriteu8(buf, (unsigned int)(value & 0xff));
}

static void mvwritesmall(sek_buf *buf, mvbytes value) {
  mvwriteu8(buf, (unsigned int)value.len);
  sek_buf_addn(buf, (const char *)value.data, value.len);
}

static void mvwritelarge(sek_buf *buf, mvbytes value) {
  mvwriteu32(buf, (unsigned long)value.len);
  sek_buf_addn(buf, (const char *)value.data, value.len);
}

static void mvwritesealed(sek_buf *buf, mvsealed value) {
  mvwritesmall(buf, value.iv);
  mvwritelarge(buf, value.blob);
}

static int mvbyid(const void *left, const void *right) {
  const mventryrecord *a = (const mventryrecord *)left;
  const mventryrecord *b = (const mventryrecord *)right;
  size_t shorter = a->id.len < b->id.len ? a->id.len : b->id.len;
  int order = 0 == shorter ? 0 : memcmp(a->id.data, b->id.data, shorter);

  if (0 != order) {
    return order;
  }

  return a->id.len < b->id.len ? -1 : (a->id.len > b->id.len ? 1 : 0);
}

static mvbytes mvwritefile(sek_pool *pool, mvfile *file) {
  sek_buf buf;
  mventryrecord *sorted;
  mvbytes out;
  size_t at;

  sek_buf_init(&buf, pool);
  sek_buf_add(&buf, MV_MAGIC);
  mvwriteu8(&buf, MV_FORMAT);
  mvwriteu8(&buf, MV_KDF_PBKDF2);
  mvwriteu8(&buf, MV_CIPHER_AESGCM);
  mvwriteu8(&buf, 0);

  mvwriteu32(&buf, (unsigned long)file->keylen);
  for (at = 0; at < file->keylen; at++) {
    mvwritesmall(&buf, mvoftext(pool, file->keys[at].id));
    mvwritesmall(&buf, file->keys[at].salt);
    mvwriteu32(&buf, (unsigned long)file->keys[at].iters);
    mvwritesealed(&buf, file->keys[at].ring);
    mvwritesealed(&buf, file->keys[at].meta);
  }

  /* SORTED BY ID, which is a blinded value: the file therefore records
   * nothing about the order secrets were written in. */
  sorted = (mventryrecord *)sek_alloc(pool, (0 == file->entrylen ? 1 : file->entrylen) *
                                                sizeof(mventryrecord));
  if (0 < file->entrylen) {
    memcpy(sorted, file->entries, file->entrylen * sizeof(mventryrecord));
    qsort(sorted, file->entrylen, sizeof(mventryrecord), mvbyid);
  }

  mvwriteu32(&buf, (unsigned long)file->entrylen);
  for (at = 0; at < file->entrylen; at++) {
    mvwritesmall(&buf, sorted[at].id);
    mvwritesealed(&buf, sorted[at].name);
    mvwritesealed(&buf, sorted[at].value);
  }

  out.data = (unsigned char *)buf.data;
  out.len = buf.len;

  return out;
}

/* ---- the vault ----------------------------------------------------- */

typedef struct {
  const char *name;
  mvbytes key;
} mvgrant;

/* THE LOCK EVERY HANDLE ON ONE FILE SHARES.
 *
 * Each handle is its own object, so two handles on one path did not
 * coordinate: both could finish `mvload` before either saved, and the
 * second rename then discarded the first one's change while reporting
 * success. Keyed by the ABSOLUTE path, so two handles spelled differently
 * still meet.
 *
 * A guarantee WITHIN one process, which is what DOCS.md promises and what
 * the go port arranges the same way. Two processes still race, and the
 * format's answer to that is the exclusive create and the atomic rename:
 * a reader sees one whole vault or the other, never half of one.
 *
 * MALLOC, NOT A POOL. This table outlives every handle in it and every
 * pool a caller owns, and freeing a mutex a thread might still be waiting
 * on is the bug it exists to avoid. A mutex is small and a process opens
 * few vaults, so it is made once and never dropped.
 *
 * THE PORT LINKS -lpthread FOR THIS, and nothing else. On glibc 2.34 and
 * later those symbols are in libc and the flag is a no-op; elsewhere it
 * is what a POSIX program links to hold a lock. */
typedef struct {
  char *file;
  /* A POINTER, and the table holds pointers rather than mutexes by value:
   * `realloc` MOVES the array, and every caller already holding a lock
   * would be holding one at the old address. */
  pthread_mutex_t *lock;
} mvheld;

static pthread_mutex_t MV_LOCKSMUTEX = PTHREAD_MUTEX_INITIALIZER;
static mvheld *MV_LOCKS = NULL;
static size_t MV_LOCKCOUNT = 0;

static pthread_mutex_t *mvlockfor(const char *file) {
  char *key = realpath(file, NULL);
  const char *want = NULL == key ? file : key;
  pthread_mutex_t *made = NULL;
  char *owned = NULL;
  mvheld *grown;
  size_t at;

  pthread_mutex_lock(&MV_LOCKSMUTEX);

  for (at = 0; at < MV_LOCKCOUNT; at++) {
    if (0 == strcmp(MV_LOCKS[at].file, want)) {
      pthread_mutex_t *found = MV_LOCKS[at].lock;
      pthread_mutex_unlock(&MV_LOCKSMUTEX);
      free(key);
      return found;
    }
  }

  if (NULL != key) {
    owned = key;
  } else {
    owned = malloc(strlen(want) + 1);
    if (NULL != owned) {
      memcpy(owned, want, strlen(want) + 1);
    }
  }

  made = malloc(sizeof(pthread_mutex_t));
  grown = realloc(MV_LOCKS, (MV_LOCKCOUNT + 1) * sizeof(mvheld));

  if (NULL == owned || NULL == made || NULL == grown) {
    if (NULL != grown) {
      MV_LOCKS = grown;
    }
    pthread_mutex_unlock(&MV_LOCKSMUTEX);
    free(owned);
    free(made);
    return NULL;
  }

  MV_LOCKS = grown;
  pthread_mutex_init(made, NULL);
  MV_LOCKS[MV_LOCKCOUNT].file = owned;
  MV_LOCKS[MV_LOCKCOUNT].lock = made;
  MV_LOCKCOUNT++;

  pthread_mutex_unlock(&MV_LOCKSMUTEX);

  return made;
}

struct sek_minivault {
  sek_pool *pool;
  const char *file;
  const char *key;
  const char *passphrase;
  int iterations;
  int create;
  /* Where MV_VAULTS holds this handle, so that a definition can export
   * an index; see MV_VAULTS. */
  size_t slot;

  /* The derived state, kept between calls: stretching a passphrase once
   * per lookup is what this caching exists to avoid. */
  int opened;
  sek_vaultinfo info;
  int hasroot;
  mvbytes root;
  mvgrant *grants;
  size_t grantlen;
  /* THE SEALED RING THIS WAS DERIVED FROM, kept so that every later call
   * can check the file still says the same thing. A handle that cached
   * its keys and never looked again kept reading a vault after its key
   * was revoked, which is the one thing `revoke` promises. */
  mvsealed ring;
};

/* The vaults this object has built.
 *
 * voxgig/plugin's values are numbers and strings, never pointers, so a
 * definition exports the INDEX of what it made and the reader looks it
 * up - exactly as `provider_define` exports an index into the core's
 * construction slot. That slot is scoped to one `sek_new` and this one
 * is not, because `sek_vaultof` is called afterwards, so this list is
 * malloc'd rather than pool-owned: a pool-owned list would be freed
 * while the file-scope pointer still named it.
 *
 * It never shrinks: one pointer per minivault store ever constructed,
 * which is strictly less than the per-chain growth of voxgig/plugin's
 * own arena that sek_pool_free's comment already documents. A vault
 * itself is pool-owned like everything else here and dies with its pool,
 * and reading one afterwards is the same use-after-free as reading any
 * other pointer this library returned.
 *
 * ONE CONSTRUCTION AT A TIME, as sek_new says of itself. */
static sek_minivault **MV_VAULTS = NULL;
static size_t MV_VAULTLEN = 0;
static size_t MV_VAULTCAP = 0;

static int mvkeep(sek_minivault *vault, size_t *out) {
  if (MV_VAULTLEN == MV_VAULTCAP) {
    size_t cap = 0 == MV_VAULTCAP ? 8 : MV_VAULTCAP * 2;
    sek_minivault **bigger =
        (sek_minivault **)realloc(MV_VAULTS, cap * sizeof(sek_minivault *));
    if (NULL == bigger) {
      return 0;
    }
    MV_VAULTS = bigger;
    MV_VAULTCAP = cap;
  }

  MV_VAULTS[MV_VAULTLEN] = vault;
  *out = MV_VAULTLEN++;

  return 1;
}

const char *sek_vault_file(sek_minivault *vault) { return vault->file; }
const char *sek_vault_key(sek_minivault *vault) { return vault->key; }

void sek_vault_close(sek_minivault *vault) {
  vault->opened = 0;
  vault->hasroot = 0;
  vault->grants = NULL;
  vault->grantlen = 0;
  memset(&vault->ring, 0, sizeof(vault->ring));
  memset(&vault->info, 0, sizeof(vault->info));
}

sek_err sek_vault_open(sek_pool *pool, const sek_vaultoptions *options, sek_minivault **out) {
  sek_minivault *vault;
  const char *key;
  sek_err err;

  *out = NULL;

  if (NULL == options || sek_empty(options->file)) {
    return mvfail(pool, "a vault needs a file");
  }
  if (sek_empty(options->passphrase)) {
    return mvfail(pool, "a vault needs a passphrase");
  }

  key = sek_empty(options->key) ? SEK_VAULT_MASTERKEY : options->key;

  err = mvcheckid(pool, key, "a vault needs a key id");
  if (NULL != err) {
    return err;
  }

  vault = (sek_minivault *)sek_alloc(pool, sizeof(sek_minivault));
  vault->pool = pool;
  vault->file = sek_strdup(pool, options->file);
  vault->key = sek_strdup(pool, key);
  vault->passphrase = sek_strdup(pool, options->passphrase);
  vault->iterations = 0 < options->iterations ? options->iterations : SEK_VAULT_ITERATIONS;
  vault->create = options->create;

  if (!mvkeep(vault, &vault->slot)) {
    return mvfail(pool, "out of memory");
  }

  *out = vault;

  return NULL;
}

/* ---- reading and writing the file ---------------------------------- */

/* The whole file as bytes.
 *
 * `sek_readfile` is the core's, and answers a C string: a vault is binary
 * and full of NULs, so this reads its own. */
static sek_err mvslurp(sek_pool *pool, const char *path, mvbytes *out, int *why) {
  sek_buf buf;
  char chunk[8192];
  int fd;

  *why = 0;
  sek_buf_init(&buf, pool);

  fd = open(path, O_RDONLY);
  if (0 > fd) {
    *why = errno;
    return mvfail(pool, "cannot read %s", path);
  }

  for (;;) {
    ssize_t got = read(fd, chunk, sizeof(chunk));
    if (0 == got) {
      break;
    }
    if (0 > got) {
      if (EINTR == errno) {
        continue;
      }
      *why = errno;
      close(fd);
      return mvfail(pool, "cannot read %s", path);
    }
    sek_buf_addn(&buf, chunk, (size_t)got);
  }

  close(fd);

  out->data = (unsigned char *)buf.data;
  out->len = buf.len;

  return NULL;
}

/* Every byte, or the errno that stopped it. */
static sek_err mvspill(sek_pool *pool, const char *path, mvbytes raw, int exclusive, int *why) {
  int fd;
  size_t at = 0;

  *why = 0;

  /* Owner-only, because a vault file is the whole store. An exclusive
   * create refuses an existing path and will not follow a symlink to
   * make one, which is what makes the temporary below safe to name in a
   * directory somebody else can write. */
  fd = open(path, O_WRONLY | O_CREAT | (exclusive ? O_EXCL : O_TRUNC), 0600);
  if (0 > fd) {
    *why = errno;
    return mvfail(pool, "cannot write %s", path);
  }

  while (at < raw.len) {
    ssize_t put = write(fd, raw.data + at, raw.len - at);
    if (0 > put) {
      if (EINTR == errno) {
        continue;
      }
      *why = errno;
      close(fd);
      unlink(path);
      return mvfail(pool, "cannot write %s", path);
    }
    at += (size_t)put;
  }

  if (0 != close(fd)) {
    *why = errno;
    unlink(path);
    return mvfail(pool, "cannot write %s", path);
  }

  return NULL;
}

/* Replaces the file rather than editing it in place. The rename is what
 * makes a concurrent reader see either the old file or the new one, so a
 * write interrupted halfway leaves a vault rather than wreckage.
 *
 * THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
 * anyone can predict, and an ordinary create FOLLOWS a symlink, so
 * anyone who could write the vault's directory could point that name at
 * another file and have the next save truncate it. */
static sek_err mvsave(sek_minivault *vault, sek_pool *work, mvfile *file) {
  mvbytes suffix;
  const char *temp;
  sek_err err = mvrandom(work, 8, &suffix);
  int why = 0;

  if (NULL != err) {
    return sek_strdup(vault->pool, err);
  }

  temp = sek_fmt(work, "%s.%s.tmp", vault->file, mvhex(work, suffix));

  err = mvspill(work, temp, mvwritefile(work, file), 1, &why);
  if (NULL != err) {
    return mvfail(vault->pool, "cannot write %s", vault->file);
  }

  if (0 != rename(temp, vault->file)) {
    /* The vault is unchanged either way, and the write error is what the
     * caller needs to be told about. */
    unlink(temp);
    return mvfail(vault->pool, "cannot write %s", vault->file);
  }

  return NULL;
}

/* Writes a vault file that is not there yet, and REFUSES one that is.
 *
 * Straight to the target under an exclusive create rather than through a
 * temporary and a rename. A rename REPLACES its destination, so two
 * processes creating the same vault both succeeded and the second
 * discarded the first one's secrets; a stat beforehand only narrows that
 * window. There is nothing to lose by writing the target directly here,
 * because there is no file to damage: either this call creates it or it
 * fails. */
static sek_err mvputnew(sek_minivault *vault, sek_pool *work, mvfile *file) {
  int why = 0;
  sek_err err = mvspill(work, vault->file, mvwritefile(work, file), 1, &why);

  if (NULL == err) {
    return NULL;
  }

  if (EEXIST == why) {
    return mvfail(vault->pool, "vault file already exists: %s", vault->file);
  }

  return mvfail(vault->pool, "cannot write %s", vault->file);
}

static sek_err mvsealkey(sek_pool *pool, mvbytes root, const char *id, const char *passphrase,
                         int iters, const char *ring, const char *meta, mvkeyrecord *out) {
  sek_err err;

  memset(out, 0, sizeof(*out));
  out->id = sek_strdup(pool, id);
  out->iters = iters;

  err = mvrandom(pool, MV_SALTLEN, &out->salt);
  if (NULL == err) {
    mvbytes kek;
    err = mvkek(pool, passphrase, out->salt, iters, &kek);
    if (NULL == err) {
      err = mvseal(pool, kek, mvoftext(pool, ring), sek_fmt(pool, "%s%s", MV_AAD_RING, id),
                   &out->ring);
    }
  }
  if (NULL == err) {
    err = mvseal(pool, mvmac(pool, root, MV_LABEL_META), mvoftext(pool, meta),
                 sek_fmt(pool, "%s%s", MV_AAD_META, id), &out->meta);
  }

  return err;
}

/* The one key record a new or rotated vault starts with: a master
 * holding the root, granted nothing because it needs nothing. */
static sek_err mvmasterkey(sek_pool *pool, mvbytes root, const char *id, const char *passphrase,
                           int iters, mvkeyrecord *out) {
  const char *ring = sek_fmt(pool, "{\"v\":%d,\"write\":true,\"root\":%s}", MV_FORMAT,
                             sek_json_quote(pool, mvb64(pool, root)));
  const char *meta =
      sek_fmt(pool, "{\"v\":%d,\"master\":true,\"write\":true,\"grants\":[]}", MV_FORMAT);

  return mvsealkey(pool, root, id, passphrase, iters, ring, meta, out);
}

static sek_err mvnewvault(sek_minivault *vault, sek_pool *work, const char *keyid,
                          const char *passphrase, int iterations, mvfile *out) {
  mvbytes root;
  mvkeyrecord record;
  sek_err err = mvrandom(work, MV_KEYLEN, &root);

  memset(out, 0, sizeof(*out));
  out->pool = work;

  if (NULL == err) {
    err = mvmasterkey(work, root, keyid, passphrase, iterations, &record);
  }
  if (NULL != err) {
    return sek_strdup(vault->pool, err);
  }

  mvaddkey(out, record);

  return NULL;
}

static sek_err mvbytesof(sek_minivault *vault, sek_pool *work, mvbytes *out) {
  int why = 0;
  sek_err err = mvslurp(work, vault->file, out, &why);

  if (NULL == err) {
    return NULL;
  }

  /* A vault is configured deliberately, with a key. Its absence is a
   * broken deployment and never "no secrets here": answering a miss
   * would send the chain on to a weaker store, which is the failure mode
   * this library most has to avoid. `create` is the caller saying the
   * opposite, in writing. */
  if (sek_absent(why)) {
    mvfile fresh;

    if (!vault->create) {
      return mvfail(vault->pool, "no vault file: %s", vault->file);
    }

    err = mvnewvault(vault, work, vault->key, vault->passphrase, vault->iterations, &fresh);
    if (NULL == err) {
      err = mvputnew(vault, work, &fresh);
    }
    if (NULL != err) {
      return err;
    }

    err = mvslurp(work, vault->file, out, &why);
    return NULL == err ? NULL : mvfail(vault->pool, "cannot read %s", vault->file);
  }

  return mvfail(vault->pool, "cannot read %s", vault->file);
}

/* The file as this key sees it: the parse into `work`, and - the first
 * time, or whenever the file's record for this key has changed - this
 * key's ring unwrapped into the vault's own pool. */
static sek_err mvload(sek_minivault *vault, sek_pool *work, mvfile *file) {
  sek_pool *keep = vault->pool;
  mvkeyrecord *record;
  mvbytes raw, kek, plain;
  sek_json *held, *grants;
  const char *root;
  sek_err err;
  size_t at;

  err = mvbytesof(vault, work, &raw);
  if (NULL != err) {
    return err;
  }

  err = mvreadfile(work, raw, file);
  if (NULL != err) {
    return sek_strdup(keep, err);
  }

  record = mvkeyof(file, vault->key);
  if (NULL == record) {
    /* REVOKED, or never there. Either way this handle is finished, and
     * dropping what it derived is what stops the next call answering
     * from memory. */
    sek_vault_close(vault);
    return mvfail(keep, "no such key: %s", vault->key);
  }

  /* The file still holds this key, and holds the SAME ring: a key
   * revoked and re-granted under another passphrase is a different key
   * wearing the id, and re-deriving is what refuses it. */
  if (vault->opened && mvsameseal(vault->ring, record->ring)) {
    return NULL;
  }
  sek_vault_close(vault);

  err = mvkek(work, vault->passphrase, record->salt, record->iters, &kek);
  if (NULL != err) {
    return sek_strdup(keep, err);
  }

  err = mvunseal(work, kek, record->ring, sek_fmt(work, "%s%s", MV_AAD_RING, vault->key),
                 sek_fmt(work, "wrong passphrase for key %s, or a damaged vault", vault->key),
                 &plain);
  if (NULL != err) {
    return sek_strdup(keep, err);
  }

  held = sek_json_parse(work, mvtext(work, plain));
  if (NULL == held || SEK_JSON_OBJ != held->type) {
    return mvfail(keep, "unreadable key ring for %s", vault->key);
  }

  grants = sek_json_dig(held, "grants", NULL);
  vault->info.grants = sek_list_new(keep);

  if (NULL != grants && SEK_JSON_OBJ == grants->type) {
    vault->grants = (mvgrant *)sek_alloc(keep, (0 == grants->maplen ? 1 : grants->maplen) *
                                                   sizeof(mvgrant));
    for (at = 0; at < grants->maplen; at++) {
      mvbytes key;
      const char *text = sek_json_asstr(grants->vals[at]);
      err = mvunb64(work, text, "a granted key", &key);
      if (NULL != err) {
        sek_vault_close(vault);
        return sek_strdup(keep, err);
      }
      vault->grants[vault->grantlen].name = sek_strdup(keep, grants->keys[at]);
      vault->grants[vault->grantlen].key = mvcopy(keep, key.data, key.len);
      vault->grantlen++;
      sek_list_add(vault->info.grants, grants->keys[at]);
    }
  }

  sek_list_sort(vault->info.grants);

  root = sek_json_asstr(sek_json_dig(held, "root", NULL));
  if (NULL != root) {
    mvbytes raw_root;
    err = mvunb64(work, root, "the root key", &raw_root);
    if (NULL != err) {
      sek_vault_close(vault);
      return sek_strdup(keep, err);
    }
    vault->root = mvcopy(keep, raw_root.data, raw_root.len);
    vault->hasroot = 1;
  }

  vault->ring.iv = mvcopy(keep, record->ring.iv.data, record->ring.iv.len);
  vault->ring.blob = mvcopy(keep, record->ring.blob.data, record->ring.blob.len);

  vault->info.key = vault->key;
  vault->info.master = vault->hasroot;
  vault->info.write = vault->hasroot || mvjsonbool(sek_json_dig(held, "write", NULL));
  vault->opened = 1;

  return NULL;
}

/* The root key, or a refusal naming what needed it. */
static sek_err mvrootof(sek_minivault *vault, const char *what, mvbytes *out) {
  if (!vault->hasroot) {
    return mvfail(vault->pool, "%s needs a master key, and %s is restricted", what, vault->key);
  }
  *out = vault->root;
  return NULL;
}

/* The key for one name, or zero when this key cannot reach it. */
static int mvkeyfor(sek_minivault *vault, sek_pool *work, const char *name, mvbytes *out) {
  size_t at;

  if (vault->hasroot) {
    *out = mvsecretkey(work, vault->root, name);
    return 1;
  }

  for (at = 0; at < vault->grantlen; at++) {
    if (0 == strcmp(name, vault->grants[at].name)) {
      *out = vault->grants[at].key;
      return 1;
    }
  }

  return 0;
}

/* ---- what a caller asks ---------------------------------------------- */

/* A COPY. `set` asks this whether the key may write, and handing back the
 * record that answer lives in let a caller flip its own permission. */
sek_err sek_vault_info(sek_minivault *vault, sek_vaultinfo **out) {
  sek_pool *work = sek_pool_new();
  mvfile file;
  sek_err err = mvload(vault, work, &file);
  sek_vaultinfo *copy;
  size_t at;

  *out = NULL;
  sek_pool_free(work);

  if (NULL != err) {
    return err;
  }

  copy = (sek_vaultinfo *)sek_alloc(vault->pool, sizeof(sek_vaultinfo));
  copy->key = vault->info.key;
  copy->master = vault->info.master;
  copy->write = vault->info.write;
  copy->grants = sek_list_new(vault->pool);
  for (at = 0; at < vault->info.grants->len; at++) {
    sek_list_add(copy->grants, vault->info.grants->items[at]);
  }

  *out = copy;

  return NULL;
}

sek_err sek_vault_list(sek_minivault *vault, sek_list **out) {
  sek_pool *work = sek_pool_new();
  sek_list *names = sek_list_new(vault->pool);
  mvfile file;
  sek_err err = mvload(vault, work, &file);
  size_t at;

  *out = NULL;

  if (NULL == err && vault->hasroot) {
    mvbytes namekey = mvmac(work, vault->root, MV_LABEL_NAMES);
    for (at = 0; at < file.entrylen && NULL == err; at++) {
      mvbytes plain;
      err = mvunseal(work, namekey, file.entries[at].name, MV_AAD_NAME, "a secret name is damaged",
                     &plain);
      if (NULL == err) {
        sek_list_add(names, mvtext(work, plain));
      } else {
        err = sek_strdup(vault->pool, err);
      }
    }
  } else if (NULL == err) {
    /* A restricted key has no name key, so it reports the grants it can
     * actually find: the vault never tells it what else is there. */
    for (at = 0; at < vault->info.grants->len; at++) {
      const char *name = vault->info.grants->items[at];
      mvbytes key;
      if (mvkeyfor(vault, work, name, &key) && NULL != mventryof(&file, mventryid(work, key))) {
        sek_list_add(names, name);
      }
    }
  }

  sek_pool_free(work);

  if (NULL != err) {
    return err;
  }

  sek_list_sort(names);
  *out = names;

  return NULL;
}

sek_err sek_vault_get(sek_minivault *vault, const char *name, char **out) {
  sek_pool *work;
  mvfile file;
  mvbytes key, plain;
  mventryrecord *entry;
  sek_err err = sek_checkname(vault->pool, name);

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  work = sek_pool_new();
  err = mvload(vault, work, &file);

  /* OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
   * key that opened it, so a name this key cannot read is a name this
   * store does not hold for this caller - the same answer a stranger's
   * vault gives, and the one that makes a restricted key in front of a
   * broader store a workable chain. */
  if (NULL == err && mvkeyfor(vault, work, name, &key)) {
    entry = mventryof(&file, mventryid(work, key));
    if (NULL != entry) {
      err = mvunseal(work, key, entry->value, sek_fmt(work, "%s%s", MV_AAD_SECRET, name),
                     sek_fmt(work, "the value of %s is damaged", name), &plain);
      if (NULL == err) {
        *out = mvtext(vault->pool, plain);
      } else {
        err = sek_strdup(vault->pool, err);
      }
    }
  }

  sek_pool_free(work);

  return err;
}

sek_err sek_vault_has(sek_minivault *vault, const char *name, int *out) {
  char *found = NULL;
  sek_err err = sek_vault_get(vault, name, &found);

  *out = NULL != found;

  return err;
}

static sek_err mvset(sek_minivault *vault, const char *name, const char *value) {
  sek_pool *work;
  mvfile file;
  mvbytes key, id;
  mvsealed box;
  mventryrecord *entry;
  sek_err err = sek_checkname(vault->pool, name);

  if (NULL != err) {
    return err;
  }

  work = sek_pool_new();
  err = mvload(vault, work, &file);

  if (NULL == err && !vault->info.write) {
    err = mvfail(vault->pool, "key %s is read-only", vault->key);
  }
  if (NULL == err && !mvkeyfor(vault, work, name, &key)) {
    err = mvfail(vault->pool, "key %s was not granted %s", vault->key, name);
  }
  if (NULL == err) {
    err = mvseal(work, key, mvoftext(work, value), sek_fmt(work, "%s%s", MV_AAD_SECRET, name),
                 &box);
    if (NULL != err) {
      err = sek_strdup(vault->pool, err);
    }
  }

  if (NULL == err) {
    id = mventryid(work, key);
    entry = mventryof(&file, id);

    if (NULL != entry) {
      entry->value = box;
    } else {
      /* A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
       * restricted key with `write` updates what it was granted and
       * cannot grow the vault, which is what "restricted" has to mean
       * for the grant list to stay the whole story. */
      mvbytes root;
      err = mvrootof(vault, sek_fmt(vault->pool, "creating the secret %s", name), &root);
      if (NULL == err) {
        mventryrecord made;
        mvsealed sealedname;
        err = mvseal(work, mvmac(work, root, MV_LABEL_NAMES), mvoftext(work, name), MV_AAD_NAME,
                     &sealedname);
        if (NULL == err) {
          made.id = id;
          made.name = sealedname;
          made.value = box;
          mvaddentry(&file, made);
        } else {
          err = sek_strdup(vault->pool, err);
        }
      }
    }
  }

  if (NULL == err) {
    err = mvsave(vault, work, &file);
  }

  sek_pool_free(work);

  return err;
}

/* Every write on this file, from any handle in this process, serializes
 * here; see mvlockfor. */
sek_err sek_vault_set(sek_minivault *vault, const char *name, const char *value) {
  sek_err err;
  pthread_mutex_t *one = mvlockfor(vault->file);

  if (NULL == one) {
    return mvfail(vault->pool, "out of memory");
  }

  pthread_mutex_lock(one);
  err = mvset(vault, name, value);
  pthread_mutex_unlock(one);

  return err;
}

static sek_err mvremove(sek_minivault *vault, const char *name) {
  sek_pool *work;
  mvfile file;
  mvbytes root, want;
  sek_err err = sek_checkname(vault->pool, name);
  size_t at, kept = 0;
  int found = 0;

  if (NULL != err) {
    return err;
  }

  work = sek_pool_new();
  err = mvload(vault, work, &file);

  if (NULL == err) {
    err = mvrootof(vault, "removing a secret", &root);
  }

  if (NULL == err) {
    want = mventryid(work, mvsecretkey(work, root, name));

    for (at = 0; at < file.entrylen; at++) {
      if (!found && mvsame(want, file.entries[at].id)) {
        found = 1;
        continue;
      }
      file.entries[kept++] = file.entries[at];
    }

    if (found) {
      file.entrylen = kept;
      err = mvsave(vault, work, &file);
    } else {
      err = mvfail(vault->pool, "no such secret: %s", name);
    }
  }

  sek_pool_free(work);

  return err;
}

/* Every write on this file, from any handle in this process, serializes
 * here; see mvlockfor. */
sek_err sek_vault_remove(sek_minivault *vault, const char *name) {
  sek_err err;
  pthread_mutex_t *one = mvlockfor(vault->file);

  if (NULL == one) {
    return mvfail(vault->pool, "out of memory");
  }

  pthread_mutex_lock(one);
  err = mvremove(vault, name);
  pthread_mutex_unlock(one);

  return err;
}

sek_err sek_vault_keys(sek_minivault *vault, sek_vaultinfo ***out, size_t *count) {
  sek_pool *work = sek_pool_new();
  mvfile file;
  mvbytes root, metakey;
  sek_err err = mvload(vault, work, &file);
  sek_vaultinfo **made = NULL;
  size_t at;

  *out = NULL;
  *count = 0;

  if (NULL == err) {
    err = mvrootof(vault, "listing the keys", &root);
  }

  if (NULL == err) {
    metakey = mvmac(work, root, MV_LABEL_META);
    made = (sek_vaultinfo **)sek_alloc(vault->pool, (0 == file.keylen ? 1 : file.keylen) *
                                                        sizeof(sek_vaultinfo *));

    for (at = 0; at < file.keylen && NULL == err; at++) {
      sek_vaultinfo *info = (sek_vaultinfo *)sek_alloc(vault->pool, sizeof(sek_vaultinfo));
      mvbytes plain;

      info->key = sek_strdup(vault->pool, file.keys[at].id);
      info->grants = sek_list_new(vault->pool);

      /* A record written under a root key this one has replaced is still
       * in the file and still opens with its own passphrase, so it is
       * reported rather than hidden - with what it can do unknown. */
      if (NULL == mvunseal(work, metakey, file.keys[at].meta,
                           sek_fmt(work, "%s%s", MV_AAD_META, file.keys[at].id), "metadata",
                           &plain)) {
        sek_json *noted = sek_json_parse(work, mvtext(work, plain));
        sek_json *grants;

        if (NULL == noted || SEK_JSON_OBJ != noted->type) {
          err = mvfail(vault->pool, "unreadable metadata for key %s", file.keys[at].id);
        } else {
          info->master = mvjsonbool(sek_json_dig(noted, "master", NULL));
          info->write = mvjsonbool(sek_json_dig(noted, "write", NULL));

          grants = sek_json_dig(noted, "grants", NULL);
          if (NULL != grants && SEK_JSON_ARR == grants->type) {
            size_t index;
            for (index = 0; index < grants->itemlen; index++) {
              const char *name = sek_json_asstr(grants->items[index]);
              if (NULL != name) {
                sek_list_add(info->grants, name);
              }
            }
          }
          sek_list_sort(info->grants);
        }
      }

      made[at] = info;
    }
  }

  if (NULL == err) {
    *out = made;
    *count = file.keylen;
  }

  sek_pool_free(work);

  return err;
}

static sek_err mvmakegrant(sek_minivault *vault, const sek_vaultgrant *spec) {
  sek_pool *work = sek_pool_new();
  mvfile file;
  mvbytes root;
  sek_err err = mvload(vault, work, &file);
  sek_buf ring, meta;
  sek_list *names;
  mvkeyrecord record;
  size_t at;

  if (NULL == err) {
    err = mvrootof(vault, "granting a key", &root);
  }
  if (NULL == err) {
    err = mvcheckid(vault->pool, NULL == spec ? NULL : spec->key, "a grant needs a key id");
  }
  if (NULL == err && sek_empty(spec->passphrase)) {
    err = mvfail(vault->pool, "a grant needs a passphrase");
  }
  if (NULL == err && NULL != mvkeyof(&file, spec->key)) {
    err = mvfail(vault->pool, "key already exists: %s", spec->key);
  }

  if (NULL != err) {
    sek_pool_free(work);
    return err;
  }

  names = sek_list_new(work);
  if (NULL != spec->names) {
    for (at = 0; at < spec->names->len; at++) {
      sek_list_add(names, spec->names->items[at]);
    }
  }
  sek_list_sort(names);

  /* Written out rather than built as a sek_json and stringified, because
   * `false` and `true` must be literals and the two documents are three
   * fields each. Every string goes through the JSON quoter: a name is
   * `[a-z0-9_.]` by the time it reaches here, but "this cannot contain a
   * quote" is exactly the assumption that stops being true when a rule
   * moves. */
  sek_buf_init(&ring, work);
  sek_buf_addfmt(&ring, "{\"v\":%d,\"write\":%s,\"grants\":{", MV_FORMAT,
                 spec->write ? "true" : "false");

  sek_buf_init(&meta, work);
  sek_buf_addfmt(&meta, "{\"v\":%d,\"master\":false,\"write\":%s,\"grants\":[", MV_FORMAT,
                 spec->write ? "true" : "false");

  for (at = 0; at < names->len && NULL == err; at++) {
    const char *name = names->items[at];

    err = sek_checkname(vault->pool, name);
    if (NULL != err) {
      break;
    }

    if (0 < at) {
      sek_buf_addch(&ring, ',');
      sek_buf_addch(&meta, ',');
    }

    sek_buf_addfmt(&ring, "%s:%s", sek_json_quote(work, name),
                   sek_json_quote(work, mvb64(work, mvsecretkey(work, root, name))));
    sek_buf_add(&meta, sek_json_quote(work, name));
  }

  sek_buf_add(&ring, "}}");
  sek_buf_add(&meta, "]}");

  if (NULL == err) {
    err = mvsealkey(work, root, spec->key, spec->passphrase,
                    0 < spec->iterations ? spec->iterations : vault->iterations, ring.data,
                    meta.data, &record);
    if (NULL != err) {
      err = sek_strdup(vault->pool, err);
    }
  }

  if (NULL == err) {
    mvaddkey(&file, record);
    err = mvsave(vault, work, &file);
  }

  sek_pool_free(work);

  return err;
}

/* Every write on this file, from any handle in this process, serializes
 * here; see mvlockfor. */
sek_err sek_vault_grant(sek_minivault *vault, const sek_vaultgrant *spec) {
  sek_err err;
  pthread_mutex_t *one = mvlockfor(vault->file);

  if (NULL == one) {
    return mvfail(vault->pool, "out of memory");
  }

  pthread_mutex_lock(one);
  err = mvmakegrant(vault, spec);
  pthread_mutex_unlock(one);

  return err;
}

static sek_err mvrevoke(sek_minivault *vault, const char *key) {
  sek_pool *work = sek_pool_new();
  mvfile file;
  mvbytes root;
  sek_err err = mvload(vault, work, &file);
  size_t at, kept = 0;

  if (NULL == err) {
    err = mvrootof(vault, "revoking a key", &root);
  }
  if (NULL == err && !sek_empty(key) && 0 == strcmp(key, vault->key)) {
    err = mvfail(vault->pool, "a key cannot revoke itself: %s", key);
  }
  if (NULL == err && (sek_empty(key) || NULL == mvkeyof(&file, key))) {
    err = mvfail(vault->pool, "no such key: %s", sek_orempty(key));
  }

  if (NULL == err) {
    for (at = 0; at < file.keylen; at++) {
      if (0 != strcmp(key, file.keys[at].id)) {
        file.keys[kept++] = file.keys[at];
      }
    }
    file.keylen = kept;

    err = mvsave(vault, work, &file);
  }

  sek_pool_free(work);

  return err;
}

/* Every write on this file, from any handle in this process, serializes
 * here; see mvlockfor. */
sek_err sek_vault_revoke(sek_minivault *vault, const char *key) {
  sek_err err;
  pthread_mutex_t *one = mvlockfor(vault->file);

  if (NULL == one) {
    return mvfail(vault->pool, "out of memory");
  }

  pthread_mutex_lock(one);
  err = mvrevoke(vault, key);
  pthread_mutex_unlock(one);

  return err;
}

static sek_err mvrotate(sek_minivault *vault) {
  sek_pool *work = sek_pool_new();
  mvfile file, fresh;
  mvbytes oldroot, oldnamekey, root, namekey;
  sek_err err = mvload(vault, work, &file);
  sek_list *names = NULL;
  sek_list *values = NULL;
  mvkeyrecord record;
  int iters = 0;
  size_t at;

  if (NULL == err) {
    err = mvrootof(vault, "rotating the vault", &oldroot);
  }

  if (NULL == err) {
    iters = mvkeyof(&file, vault->key)->iters;
    names = sek_list_new(work);
    values = sek_list_new(work);

    /* Read everything out under the old root before anything changes:
     * once the root is replaced the old derived keys are unreachable. */
    oldnamekey = mvmac(work, oldroot, MV_LABEL_NAMES);

    for (at = 0; at < file.entrylen && NULL == err; at++) {
      mvbytes plain, value;
      err = mvunseal(work, oldnamekey, file.entries[at].name, MV_AAD_NAME,
                     "a secret name is damaged", &plain);
      if (NULL == err) {
        const char *name = mvtext(work, plain);
        err = mvunseal(work, mvsecretkey(work, oldroot, name), file.entries[at].value,
                       sek_fmt(work, "%s%s", MV_AAD_SECRET, name),
                       sek_fmt(work, "the value of %s is damaged", name), &value);
        if (NULL == err) {
          sek_list_add(names, name);
          sek_list_add(values, mvtext(work, value));
        }
      }
      if (NULL != err) {
        err = sek_strdup(vault->pool, err);
      }
    }
  }

  if (NULL == err) {
    err = mvrandom(work, MV_KEYLEN, &root);
    if (NULL != err) {
      err = sek_strdup(vault->pool, err);
    }
  }

  if (NULL == err) {
    memset(&fresh, 0, sizeof(fresh));
    fresh.pool = work;
    namekey = mvmac(work, root, MV_LABEL_NAMES);

    for (at = 0; at < names->len && NULL == err; at++) {
      const char *name = names->items[at];
      mvbytes key = mvsecretkey(work, root, name);
      mventryrecord made;

      err = mvseal(work, namekey, mvoftext(work, name), MV_AAD_NAME, &made.name);
      if (NULL == err) {
        err = mvseal(work, key, mvoftext(work, values->items[at]),
                     sek_fmt(work, "%s%s", MV_AAD_SECRET, name), &made.value);
      }
      if (NULL == err) {
        made.id = mventryid(work, key);
        mvaddentry(&fresh, made);
      } else {
        err = sek_strdup(vault->pool, err);
      }
    }
  }

  if (NULL == err) {
    err = mvmasterkey(work, root, vault->key, vault->passphrase, iters, &record);
    if (NULL != err) {
      err = sek_strdup(vault->pool, err);
    }
  }

  if (NULL == err) {
    mvaddkey(&fresh, record);

    /* SAVE FIRST, adopt second. A handle holding the new root over a
     * file that still holds the old one reads nothing and says the vault
     * is damaged, which is the wrong story about a failed write. */
    err = mvsave(vault, work, &fresh);

    /* Dropped rather than replaced: the next call re-derives from the
     * file this one just wrote, which is the same rule every other
     * change follows. */
    if (NULL == err) {
      sek_vault_close(vault);
    }
  }

  sek_pool_free(work);

  return err;
}

/* Every write on this file, from any handle in this process, serializes
 * here; see mvlockfor. */
sek_err sek_vault_rotate(sek_minivault *vault) {
  sek_err err;
  pthread_mutex_t *one = mvlockfor(vault->file);

  if (NULL == one) {
    return mvfail(vault->pool, "out of memory");
  }

  pthread_mutex_lock(one);
  err = mvrotate(vault);
  pthread_mutex_unlock(one);

  return err;
}

sek_err sek_vault_create(sek_pool *pool, const sek_vaultoptions *options, sek_minivault **out) {
  sek_pool *work;
  mvfile fresh;
  sek_err err = sek_vault_open(pool, options, out);

  if (NULL != err) {
    return err;
  }

  work = sek_pool_new();

  /* No stat first: the check and the write would be two steps, and
   * `mvputnew` refuses an existing file in ONE, which is what makes two
   * processes racing to create a vault leave one vault. */
  err = mvnewvault(*out, work, (*out)->key, (*out)->passphrase, (*out)->iterations, &fresh);
  if (NULL == err) {
    err = mvputnew(*out, work, &fresh);
  }

  sek_pool_free(work);

  if (NULL != err) {
    *out = NULL;
  }

  return err;
}

/* ---- the provider -------------------------------------------------- */

/* The provider is the READ half and nothing more: a chain resolves
 * secrets, and writing one is a deliberate act with an API of its own.
 * That API is the same handle, reached with `sek_vaultof` off a chain or
 * built directly with `sek_vault_open`. */
typedef struct {
  sek_minivault *vault;
  char *described;
} minivaultdata;

static sek_err minivault_lookup(sek_provider *self, const char *name, char **out) {
  return sek_vault_get(((minivaultdata *)self->data)->vault, name, out);
}

static const char *minivault_describe(sek_provider *self) {
  return ((minivaultdata *)self->data)->described;
}

/* Written out rather than built by `sek_providerplugin`, because this
 * definition publishes TWO exports: `provider`, the read half every kind
 * publishes, and `vault`, the programmatic API. voxgig/plugin's exports
 * are how a definition offers an application more than the host's own
 * vocabulary, and a store that can only be read is half a vault.
 *
 * The `sekreto_error` wrapping is what `sek_providerplugin` would have
 * done: plugin wraps a code-less error raised in `define` as
 * `plugin_define_failed` and keeps one that already carries a code, so a
 * refusal of this provider's own configuration travels under
 * `sekreto_error` and comes back out of the host as itself. */
static void minivault_define(Inst *inst) {
  sek_pool *pool = sek_build_pool();
  sek_spec spec = sek_specof(pool, inst_options(inst));
  sek_vaultoptions options;
  sek_minivault *vault = NULL;
  minivaultdata *data;
  sek_err err;

  memset(&options, 0, sizeof(options));
  options.file = spec.file;
  options.key = spec.vaultkey;
  options.passphrase = spec.passphrase;
  options.iterations = spec.iterations;
  options.create = spec.create;

  /* Configuration is refused HERE, so a mistyped chain fails at
   * construction. Reaching the file is not configuration: the handle is
   * lazy, and nothing is read or stretched until a lookup. */
  err = sek_vault_open(pool, &options, &vault);
  if (NULL != err) {
    fail(SEK_ERROR_CODE, err, details2("ref", vstr(inst_ref(inst)), "cause", vstr(err)));
  }

  data = (minivaultdata *)sek_alloc(pool, sizeof(minivaultdata));
  data->vault = vault;
  data->described = sek_fmt(pool, "minivault:%s", vault->file);

  inst_export(inst, SEK_PROVIDER_EXPORT,
              vnum(sek_build_keep(sek_provider_new(pool, minivault_lookup, minivault_describe,
                                                   data))));
  inst_export(inst, SEK_VAULT_EXPORT, vnum((double)vault->slot));
}

static Definition MINIVAULT_DEF;

Definition *sek_plugin_minivault(void) {
  memset(&MINIVAULT_DEF, 0, sizeof(MINIVAULT_DEF));

  MINIVAULT_DEF.name = "minivault";
  MINIVAULT_DEF.define = minivault_define;

  return &MINIVAULT_DEF;
}

/* The vault behind a store in a chain, as its programmatic API.
 *
 * `sek_host` is the voxgig/plugin host the chain is made of, and a
 * definition's exports are readable off it by ref. This is the one call
 * that turns a store into an API, and it lives here rather than in the
 * core because the core knows no plugin.
 *
 * With no store named, the unqualified alias answers: one vault in the
 * chain resolves whatever it is called, and two raise rather than
 * picking one.
 *
 * THE INDEX IS RANGE-CHECKED AS A DOUBLE, BEFORE THE CAST, for the reason
 * `sek_build_at` states: an export is a plugin number, so a hand-written
 * definition may put any double under this key, and converting one that
 * does not fit a size_t is undefined. `!(index < len)` rather than
 * `index >= len` so that a NaN, which compares false with everything, is
 * refused too. */
static sek_err mvslotof(sek_pool *pool, Value *found, const char *missing, sek_minivault **out) {
  double index;

  if (NULL == found || VNUM != found->kind) {
    return sek_strdup(pool, missing);
  }

  index = found->num;
  if (!(0 <= index) || !(index < (double)MV_VAULTLEN)) {
    return sek_strdup(pool, missing);
  }

  *out = MV_VAULTS[(size_t)index];

  return NULL;
}

sek_err sek_vaultof(sek_pool *pool, sek_sekreto *sek, const char *store, sek_minivault **out) {
  const char *missing;
  const char *ref;
  Value *found;

  *out = NULL;

  if (sek_empty(store)) {
    missing = "sekreto: minivault: no minivault store in this chain";
    return mvslotof(pool, host_exports(sek_host(sek), "minivault/" SEK_VAULT_EXPORT), missing,
                    out);
  }

  /* A NAMED STORE MUST EXIST, and the alias must not stand in for it.
   * `host_exports` falls back to the alias when the exact ref misses, so
   * asking for `minivault` in a chain whose only vault is named `app`
   * used to hand back the `app` vault - and then write to it. Naming a
   * store that is not there refuses, which is the rule the whole library
   * follows: `sek_try` already means "may not have it", so it cannot
   * also mean "may not exist". */
  missing = sek_fmt(pool, "sekreto: minivault: no minivault store named %s in this chain", store);
  ref = 0 == strcmp("minivault", store) ? "minivault" : sek_fmt(pool, "minivault$%s", store);

  if (NULL == host_instance(sek_host(sek), ref)) {
    return sek_strdup(pool, missing);
  }

  found = host_exports(sek_host(sek), sek_fmt(pool, "%s/%s", ref, SEK_VAULT_EXPORT));

  return mvslotof(pool, found, missing, out);
}
