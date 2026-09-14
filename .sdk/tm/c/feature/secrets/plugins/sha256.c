// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/sha256.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* SHA-256 and HMAC-SHA256, by hand.
 *
 * This port links libcrypto, and these are still written out. That is the
 * rule and not an oversight: the dependency exception in AGENTS.md covers
 * cryptographic TRANSPORT, and nothing else. Rust is the worked
 * precedent - `ring` sits inside rustls's dependency closure and
 * rust/src/crypto.rs carries both primitives anyway. Calling libcrypto's
 * EVP_Digest for a SigV4 signature would quietly widen the exception from
 * "we do not hand-roll TLS" to "we use whatever the TLS library ships",
 * which is a different and much larger claim.
 *
 * THIS OBJECT EXISTS SO THAT ONLY THE SIGNER PULLS IT. The aws plugin is
 * the only thing in the library that hashes anything, and a static
 * archive is linked an object at a time - so keeping the digest here, and
 * the base64 and percent encoders in `encode.c` where four non-signing
 * stores can reach them, is what makes "a plugin that signs nothing does
 * not link SHA-256" true rather than merely intended. `make check-core`
 * measures it.
 *
 * Correctness is not asserted, it is proved: SigV4 is a chain of these
 * primitives, so one wrong bit anywhere fails the five known-answer
 * vectors in spec/sekreto.json - including AWS's own published
 * `get-vanilla`.
 *
 * The digest is STREAMING (init/update/final) rather than one-shot,
 * because HMAC hashes the key pad followed by the message and the message
 * here is a whole request body. A one-shot digest would need those
 * concatenated into one buffer, which for the 8 MiB body cap means an 8
 * MiB allocation per signature - on the stack, if it were an alloca.
 *
 * A port of rust/src/crypto.rs.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <string.h>

#include "support.h"

/* ---- SHA-256, FIPS 180-4 ------------------------------------------- */

static const unsigned int K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u,
    0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu,
    0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu,
    0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u,
    0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u,
    0xc67178f2u};

typedef struct {
  unsigned int state[8];
  unsigned char block[64];
  size_t held;
  unsigned long long bits;
} sha256ctx;

static unsigned int ror(unsigned int val, unsigned int by) {
  return (val >> by) | (val << (32 - by));
}

static void compress(unsigned int state[8], const unsigned char block[64]) {
  unsigned int w[64];
  unsigned int a, b, c, d, e, f, g, h;
  int step;

  for (step = 0; step < 16; step++) {
    w[step] = ((unsigned int)block[step * 4] << 24) | ((unsigned int)block[step * 4 + 1] << 16) |
              ((unsigned int)block[step * 4 + 2] << 8) | (unsigned int)block[step * 4 + 3];
  }

  for (step = 16; step < 64; step++) {
    unsigned int s0 = ror(w[step - 15], 7) ^ ror(w[step - 15], 18) ^ (w[step - 15] >> 3);
    unsigned int s1 = ror(w[step - 2], 17) ^ ror(w[step - 2], 19) ^ (w[step - 2] >> 10);
    w[step] = w[step - 16] + s0 + w[step - 7] + s1;
  }

  a = state[0];
  b = state[1];
  c = state[2];
  d = state[3];
  e = state[4];
  f = state[5];
  g = state[6];
  h = state[7];

  for (step = 0; step < 64; step++) {
    unsigned int big1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
    unsigned int ch = (e & f) ^ ((~e) & g);
    unsigned int temp1 = h + big1 + ch + K[step] + w[step];
    unsigned int big0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
    unsigned int maj = (a & b) ^ (a & c) ^ (b & c);
    unsigned int temp2 = big0 + maj;

    h = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }

  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

static void sha256init(sha256ctx *ctx) {
  ctx->state[0] = 0x6a09e667u;
  ctx->state[1] = 0xbb67ae85u;
  ctx->state[2] = 0x3c6ef372u;
  ctx->state[3] = 0xa54ff53au;
  ctx->state[4] = 0x510e527fu;
  ctx->state[5] = 0x9b05688cu;
  ctx->state[6] = 0x1f83d9abu;
  ctx->state[7] = 0x5be0cd19u;
  ctx->held = 0;
  ctx->bits = 0;
  memset(ctx->block, 0, sizeof(ctx->block));
}

static void sha256update(sha256ctx *ctx, const unsigned char *data, size_t len) {
  size_t at = 0;

  ctx->bits += (unsigned long long)len * 8ull;

  if (0 < ctx->held) {
    size_t want = 64 - ctx->held;
    size_t take = want < len ? want : len;

    memcpy(ctx->block + ctx->held, data, take);
    ctx->held += take;
    at = take;

    if (64 == ctx->held) {
      compress(ctx->state, ctx->block);
      ctx->held = 0;
    }
  }

  while (len - at >= 64) {
    compress(ctx->state, data + at);
    at += 64;
  }

  if (at < len) {
    memcpy(ctx->block, data + at, len - at);
    ctx->held = len - at;
  }
}

static void sha256final(sha256ctx *ctx, unsigned char out[SEK_SHA256_LEN]) {
  unsigned long long bits = ctx->bits;
  unsigned char tail[64];
  size_t rest = ctx->held;
  int step;

  memset(tail, 0, sizeof(tail));
  memcpy(tail, ctx->block, rest);
  tail[rest] = 0x80;

  /* The 64-bit length must fit in the final block; when it does not, the
   * padded block goes out on its own first. */
  if (56 < rest + 1) {
    compress(ctx->state, tail);
    memset(tail, 0, sizeof(tail));
  }

  for (step = 0; step < 8; step++) {
    tail[63 - step] = (unsigned char)((bits >> (8 * step)) & 0xff);
  }
  compress(ctx->state, tail);

  for (step = 0; step < 8; step++) {
    out[step * 4] = (unsigned char)((ctx->state[step] >> 24) & 0xff);
    out[step * 4 + 1] = (unsigned char)((ctx->state[step] >> 16) & 0xff);
    out[step * 4 + 2] = (unsigned char)((ctx->state[step] >> 8) & 0xff);
    out[step * 4 + 3] = (unsigned char)(ctx->state[step] & 0xff);
  }
}

void sek_sha256(const unsigned char *data, size_t len, unsigned char out[SEK_SHA256_LEN]) {
  sha256ctx ctx;

  sha256init(&ctx);
  sha256update(&ctx, data, len);
  sha256final(&ctx, out);
}

/* ---- HMAC-SHA256, RFC 2104 ----------------------------------------- */

/* The argument order is (key, data), which is this repository's
 * convention. PHP's and Perl's stdlib take (data, key); a port that
 * copies one of those without fixing the order at its wrapper produces a
 * signature that is wrong in a way nothing but the vectors catches. */
void sek_hmac_sha256(const unsigned char *key, size_t keylen, const unsigned char *data,
                     size_t datalen, unsigned char out[SEK_SHA256_LEN]) {
  unsigned char shortened[SEK_SHA256_LEN];
  unsigned char pad[64];
  unsigned char inner[SEK_SHA256_LEN];
  sha256ctx ctx;
  size_t index;

  if (64 < keylen) {
    sek_sha256(key, keylen, shortened);
    key = shortened;
    keylen = SEK_SHA256_LEN;
  }

  memset(pad, 0, sizeof(pad));
  memcpy(pad, key, keylen);
  for (index = 0; index < 64; index++) {
    pad[index] = (unsigned char)(pad[index] ^ 0x36);
  }

  sha256init(&ctx);
  sha256update(&ctx, pad, 64);
  sha256update(&ctx, data, datalen);
  sha256final(&ctx, inner);

  for (index = 0; index < 64; index++) {
    /* Back out the ipad and apply the opad: 0x36 ^ 0x5c flips exactly the
     * bits that differ between them. */
    pad[index] = (unsigned char)(pad[index] ^ 0x36 ^ 0x5c);
  }

  sha256init(&ctx);
  sha256update(&ctx, pad, 64);
  sha256update(&ctx, inner, SEK_SHA256_LEN);
  sha256final(&ctx, out);
}

/* ---- hex ----------------------------------------------------------- */

char *sek_hex(sek_pool *pool, const unsigned char *bytes, size_t len) {
  static const char digits[] = "0123456789abcdef";
  char *out = (char *)sek_alloc(pool, len * 2 + 1);
  size_t index;

  for (index = 0; index < len; index++) {
    out[index * 2] = digits[(bytes[index] >> 4) & 0x0f];
    out[index * 2 + 1] = digits[bytes[index] & 0x0f];
  }
  out[len * 2] = '\0';

  return out;
}

char *sek_sha256hex(sek_pool *pool, const char *text) {
  unsigned char digest[SEK_SHA256_LEN];
  const char *use = NULL == text ? "" : text;

  sek_sha256((const unsigned char *)use, strlen(use), digest);

  return sek_hex(pool, digest, SEK_SHA256_LEN);
}
