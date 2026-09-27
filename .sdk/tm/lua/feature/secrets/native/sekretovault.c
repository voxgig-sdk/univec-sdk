-- VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (lua/native/sekretovault.c)
-- Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The four primitives the mini vault is made of, as a Lua module:
 * AES-256-GCM, PBKDF2-HMAC-SHA256, HMAC-SHA256, and the entropy under
 * them.
 *
 * THE SECOND FILE IN THIS PORT THAT NAMES OpenSSL, and the only other
 * one. `sekretonet.c` is the first, and it is taken for TRANSPORT.
 * AGENTS.md now says cryptography, because a block cipher protecting
 * secrets AT REST has properties no known-answer vector can check - a
 * table-driven AES passes every vector in the world and still hands its
 * key to anyone who can time a cache. The in-tree SHA-256 and HMAC in
 * `src/sekreto/plugins/crypto.lua` stay where they are, as the widened
 * rule says outright: they work, a SigV4 signature is a chain of them so
 * one wrong bit fails the published vectors loudly, and rewriting them
 * buys nothing.
 *
 * A LOADABLE MODULE, NOT A CHILD PROCESS, and that is the one place this
 * file differs in shape from `sekretonet.c` beside it. The transport
 * helper is a process because one HTTP round-trip is one spawn and the
 * cost disappears into the network; a vault `list` over a hundred
 * secrets is a hundred AEAD opens, and a hundred spawns is not a store
 * anybody would use. Lua loads C modules as a matter of course, so this
 * is the ordinary answer rather than a new mechanism - and the port's
 * own Makefile builds it from source, so nothing is resolved from
 * luarocks.
 *
 * Bytes travel as Lua STRINGS, which are byte sequences and may hold
 * NULs - so every length here comes from `lua_tolstring` and never from
 * `strlen`. A failure raises a Lua error, which the Lua side turns into
 * the library's own.
 */

#include <string.h>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

#define SEK_MV_KEYLEN 32
#define SEK_MV_IVLEN 12
#define SEK_MV_TAGLEN 16

/* Fresh entropy from the platform's CSPRNG. A nonce repeated under one
 * AES-GCM key loses the confidentiality of both messages, so a failure
 * here is raised rather than papered over. */
static int mv_random(lua_State *L) {
  lua_Integer len = luaL_checkinteger(L, 1);
  luaL_Buffer out;
  char *raw;

  luaL_argcheck(L, 0 <= len && 4096 >= len, 1, "a bad length");

  raw = luaL_buffinitsize(L, &out, (size_t)len);

  if (0 < len && 1 != RAND_bytes((unsigned char *)raw, (int)len)) {
    return luaL_error(L, "no randomness available");
  }

  luaL_pushresultsize(&out, (size_t)len);

  return 1;
}

/* HMAC-SHA256 of `msg` under `key`. */
static int mv_hmac(lua_State *L) {
  size_t keylen = 0;
  size_t msglen = 0;
  const char *key = luaL_checklstring(L, 1, &keylen);
  const char *msg = luaL_checklstring(L, 2, &msglen);
  unsigned char mac[EVP_MAX_MD_SIZE];
  unsigned int len = 0;

  if (NULL == HMAC(EVP_sha256(), key, (int)keylen, (const unsigned char *)msg, msglen, mac,
                   &len)) {
    return luaL_error(L, "cannot compute a mac");
  }

  lua_pushlstring(L, (const char *)mac, len);

  return 1;
}

/* PBKDF2-HMAC-SHA256.
 *
 * A round count below one is refused here rather than passed on: it is
 * what a damaged or hostile file records to make the derivation free, and
 * OpenSSL would accept it. */
static int mv_pbkdf2(lua_State *L) {
  size_t passlen = 0;
  size_t saltlen = 0;
  const char *pass = luaL_checklstring(L, 1, &passlen);
  const char *salt = luaL_checklstring(L, 2, &saltlen);
  lua_Integer iters = luaL_checkinteger(L, 3);
  luaL_Buffer out;
  char *raw;

  if (1 > iters) {
    return luaL_error(L, "unusable round count");
  }

  raw = luaL_buffinitsize(L, &out, SEK_MV_KEYLEN);

  if (1 != PKCS5_PBKDF2_HMAC(pass, (int)passlen, (const unsigned char *)salt, (int)saltlen,
                             (int)iters, EVP_sha256(), SEK_MV_KEYLEN, (unsigned char *)raw)) {
    return luaL_error(L, "cannot derive a key");
  }

  luaL_pushresultsize(&out, SEK_MV_KEYLEN);

  return 1;
}

/* AES-256-GCM, sealing. The answer is ciphertext followed by the 16-byte
 * tag, which is where every other port's AEAD leaves it and therefore
 * what the format records. */
static int mv_seal(lua_State *L) {
  size_t keylen = 0;
  size_t ivlen = 0;
  size_t plainlen = 0;
  size_t aadlen = 0;
  const char *key = luaL_checklstring(L, 1, &keylen);
  const char *iv = luaL_checklstring(L, 2, &ivlen);
  const char *plain = luaL_checklstring(L, 3, &plainlen);
  const char *aad = luaL_checklstring(L, 4, &aadlen);
  EVP_CIPHER_CTX *ctx = NULL;
  luaL_Buffer out;
  unsigned char *raw;
  int len = 0;
  int ok = 0;

  luaL_argcheck(L, SEK_MV_KEYLEN == keylen, 1, "bad key");
  luaL_argcheck(L, SEK_MV_IVLEN == ivlen, 2, "bad iv");

  raw = (unsigned char *)luaL_buffinitsize(L, &out, plainlen + SEK_MV_TAGLEN);

  ctx = EVP_CIPHER_CTX_new();
  if (NULL == ctx) {
    return luaL_error(L, "cannot seal");
  }

  ok = 1 == EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, SEK_MV_IVLEN, NULL) &&
       1 == EVP_EncryptInit_ex(ctx, NULL, NULL, (const unsigned char *)key,
                               (const unsigned char *)iv) &&
       1 == EVP_EncryptUpdate(ctx, NULL, &len, (const unsigned char *)aad, (int)aadlen) &&
       1 == EVP_EncryptUpdate(ctx, raw, &len, (const unsigned char *)plain, (int)plainlen) &&
       1 == EVP_EncryptFinal_ex(ctx, raw + len, &len) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, SEK_MV_TAGLEN, raw + plainlen);

  EVP_CIPHER_CTX_free(ctx);

  if (!ok) {
    return luaL_error(L, "cannot seal");
  }

  luaL_pushresultsize(&out, plainlen + SEK_MV_TAGLEN);

  return 1;
}

/* AES-256-GCM, opening.
 *
 * A tag that fails to verify answers nil, and the Lua side turns that
 * into the message the format's contract names. The tag is the only
 * evidence there is, and it cannot tell a wrong passphrase from a damaged
 * file - which is why this is a nil rather than an error: the caller
 * knows what it was trying to open, and this does not. */
static int mv_unseal(lua_State *L) {
  size_t keylen = 0;
  size_t ivlen = 0;
  size_t bloblen = 0;
  size_t aadlen = 0;
  const char *key = luaL_checklstring(L, 1, &keylen);
  const char *iv = luaL_checklstring(L, 2, &ivlen);
  const char *blob = luaL_checklstring(L, 3, &bloblen);
  const char *aad = luaL_checklstring(L, 4, &aadlen);
  EVP_CIPHER_CTX *ctx = NULL;
  luaL_Buffer out;
  unsigned char *raw;
  size_t cut = 0;
  int len = 0;
  int ok = 0;

  luaL_argcheck(L, SEK_MV_KEYLEN == keylen, 1, "bad key");
  luaL_argcheck(L, SEK_MV_IVLEN == ivlen, 2, "bad iv");

  if (SEK_MV_TAGLEN > bloblen) {
    lua_pushnil(L);
    return 1;
  }
  cut = bloblen - SEK_MV_TAGLEN;

  raw = (unsigned char *)luaL_buffinitsize(L, &out, cut);

  ctx = EVP_CIPHER_CTX_new();
  if (NULL == ctx) {
    return luaL_error(L, "cannot open");
  }

  ok = 1 == EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, SEK_MV_IVLEN, NULL) &&
       1 == EVP_DecryptInit_ex(ctx, NULL, NULL, (const unsigned char *)key,
                               (const unsigned char *)iv) &&
       1 == EVP_DecryptUpdate(ctx, NULL, &len, (const unsigned char *)aad, (int)aadlen) &&
       1 == EVP_DecryptUpdate(ctx, raw, &len, (const unsigned char *)blob, (int)cut) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, SEK_MV_TAGLEN,
                                (void *)(blob + cut)) &&
       0 < EVP_DecryptFinal_ex(ctx, raw + len, &len);

  EVP_CIPHER_CTX_free(ctx);

  if (!ok) {
    lua_pushnil(L);
    return 1;
  }

  luaL_pushresultsize(&out, cut);

  return 1;
}

static const luaL_Reg SEKRETOVAULT[] = {
  {"random", mv_random},
  {"hmac", mv_hmac},
  {"pbkdf2", mv_pbkdf2},
  {"seal", mv_seal},
  {"unseal", mv_unseal},
  {NULL, NULL}
};

int luaopen_sekretovault(lua_State *L) {
  luaL_newlib(L, SEKRETOVAULT);
  return 1;
}
