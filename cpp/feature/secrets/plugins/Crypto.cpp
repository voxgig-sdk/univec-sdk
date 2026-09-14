// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Crypto.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Crypto.hpp"

namespace sekreto {

namespace {

// FIPS 180-4 round constants: the first 32 bits of the fractional parts of
// the cube roots of the first 64 primes.
const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

// The eight initial hash words: the first 32 bits of the fractional parts
// of the square roots of the first 8 primes.
const uint32_t H0[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

inline uint32_t ror(uint32_t word, unsigned int bits) {
  return (word >> bits) | (word << (32 - bits));
}

const size_t BLOCK = 64;

}  // namespace

Bytes tobytes(const std::string& text) {
  return Bytes(text.begin(), text.end());
}

std::string frombytes(const Bytes& data) {
  return std::string(data.begin(), data.end());
}

Bytes sha256(const Bytes& data) {
  Bytes message = data;

  // Padding: one 0x80 byte, zeros up to 56 mod 64, then the message length
  // in BITS as a big-endian 64-bit integer.
  uint64_t bitlen = static_cast<uint64_t>(data.size()) * 8;

  message.push_back(0x80);
  while (56 != message.size() % BLOCK) {
    message.push_back(0);
  }
  for (int shift = 56; 0 <= shift; shift -= 8) {
    message.push_back(static_cast<uint8_t>((bitlen >> shift) & 0xff));
  }

  uint32_t hash[8];
  for (int index = 0; index < 8; index++) {
    hash[index] = H0[index];
  }

  for (size_t block = 0; block < message.size(); block += BLOCK) {
    uint32_t schedule[64];

    for (int index = 0; index < 16; index++) {
      size_t at = block + static_cast<size_t>(index) * 4;
      schedule[index] = (static_cast<uint32_t>(message[at]) << 24) |
                        (static_cast<uint32_t>(message[at + 1]) << 16) |
                        (static_cast<uint32_t>(message[at + 2]) << 8) |
                        static_cast<uint32_t>(message[at + 3]);
    }

    for (int index = 16; index < 64; index++) {
      uint32_t prev15 = schedule[index - 15];
      uint32_t prev2 = schedule[index - 2];
      uint32_t sigma0 = ror(prev15, 7) ^ ror(prev15, 18) ^ (prev15 >> 3);
      uint32_t sigma1 = ror(prev2, 17) ^ ror(prev2, 19) ^ (prev2 >> 10);
      schedule[index] = schedule[index - 16] + sigma0 + schedule[index - 7] + sigma1;
    }

    uint32_t a = hash[0];
    uint32_t b = hash[1];
    uint32_t c = hash[2];
    uint32_t d = hash[3];
    uint32_t e = hash[4];
    uint32_t f = hash[5];
    uint32_t g = hash[6];
    uint32_t h = hash[7];

    for (int index = 0; index < 64; index++) {
      uint32_t bigsigma1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
      uint32_t choose = (e & f) ^ (~e & g);
      uint32_t temp1 = h + bigsigma1 + choose + K[index] + schedule[index];
      uint32_t bigsigma0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
      uint32_t major = (a & b) ^ (a & c) ^ (b & c);
      uint32_t temp2 = bigsigma0 + major;

      h = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }

    hash[0] += a;
    hash[1] += b;
    hash[2] += c;
    hash[3] += d;
    hash[4] += e;
    hash[5] += f;
    hash[6] += g;
    hash[7] += h;
  }

  Bytes out;
  out.reserve(32);

  for (int index = 0; index < 8; index++) {
    out.push_back(static_cast<uint8_t>((hash[index] >> 24) & 0xff));
    out.push_back(static_cast<uint8_t>((hash[index] >> 16) & 0xff));
    out.push_back(static_cast<uint8_t>((hash[index] >> 8) & 0xff));
    out.push_back(static_cast<uint8_t>(hash[index] & 0xff));
  }

  return out;
}

Bytes hmacsha256(const Bytes& key, const Bytes& data) {
  Bytes block = key;

  // A key longer than the block is hashed down; a shorter one is padded up
  // with zeros.
  if (BLOCK < block.size()) {
    block = sha256(block);
  }
  block.resize(BLOCK, 0);

  Bytes inner;
  inner.reserve(BLOCK + data.size());
  Bytes outer;
  outer.reserve(BLOCK + 32);

  for (size_t index = 0; index < BLOCK; index++) {
    inner.push_back(static_cast<uint8_t>(block[index] ^ 0x36));
    outer.push_back(static_cast<uint8_t>(block[index] ^ 0x5c));
  }

  inner.insert(inner.end(), data.begin(), data.end());

  Bytes middle = sha256(inner);
  outer.insert(outer.end(), middle.begin(), middle.end());

  return sha256(outer);
}

std::string hex(const Bytes& data) {
  static const char DIGITS[] = "0123456789abcdef";

  std::string out;
  out.reserve(data.size() * 2);

  for (uint8_t byte : data) {
    out.push_back(DIGITS[(byte >> 4) & 0x0f]);
    out.push_back(DIGITS[byte & 0x0f]);
  }

  return out;
}

}  // namespace sekreto
