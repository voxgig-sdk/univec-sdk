// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/crypto.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SHA-256 and HMAC-SHA256, hand-rolled.
//
// UNDER `plugins/`, WITH THE AWS PLUGIN, because the core of no port
// imports a hash function: `sigv4` is the aws plugin's own business and
// this is what it is built from. A chain of the four built-in kinds never
// compiles a round of SHA-256.
//
// dart:io has no cryptography and package:crypto is a third-party package,
// so the two primitives AWS request signing is built from are written out
// here. Both are small, published and completely specified: SHA-256 is FIPS
// 180-4 and HMAC is RFC 2104.
//
// Correctness is not asserted by unit tests of the digests themselves. A
// SigV4 signature is a chain of these two primitives over a canonical
// request, so one wrong bit anywhere fails the five known-answer vectors in
// the shared spec - including AWS's own published `get-vanilla` case.
//
// A port of rust/src/crypto.rs, which is the reference hand-rolled pair.

import 'dart:convert';
import 'dart:typed_data';

/// The 64 round constants: the first 32 bits of the fractional parts of the
/// cube roots of the first 64 primes.
const List<int> _K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// The eight initial hash words: the fractional parts of the square roots of
/// the first eight primes.
const List<int> _H0 = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const int _MASK = 0xffffffff;

/// Rotate right within 32 bits. Dart integers are 64-bit, so every shift
/// and every addition below is masked back down explicitly - an unmasked
/// carry would quietly widen a word and change the digest.
int _rotr(int word, int by) =>
    ((word >> by) | (word << (32 - by))) & _MASK;

/// The SHA-256 digest of some bytes: 32 bytes.
Uint8List sha256(List<int> data) {
  // Padding: a single 1 bit, zeros up to 56 bytes mod 64, then the message
  // length in BITS as a big-endian 64-bit integer.
  final bitlen = data.length * 8;
  var padded = data.length + 1;
  while (56 != padded % 64) {
    padded++;
  }

  final block = Uint8List(padded + 8);
  block.setRange(0, data.length, data);
  block[data.length] = 0x80;

  for (var at = 0; at < 8; at++) {
    block[padded + at] = (bitlen >> (8 * (7 - at))) & 0xff;
  }

  final hash = List<int>.from(_H0);
  final schedule = List<int>.filled(64, 0);

  for (var start = 0; start < block.length; start += 64) {
    for (var at = 0; at < 16; at++) {
      final base = start + at * 4;
      schedule[at] = (block[base] << 24) |
          (block[base + 1] << 16) |
          (block[base + 2] << 8) |
          block[base + 3];
    }

    for (var at = 16; at < 64; at++) {
      final low = schedule[at - 15];
      final high = schedule[at - 2];
      final s0 = _rotr(low, 7) ^ _rotr(low, 18) ^ (low >> 3);
      final s1 = _rotr(high, 17) ^ _rotr(high, 19) ^ (high >> 10);
      schedule[at] =
          (schedule[at - 16] + s0 + schedule[at - 7] + s1) & _MASK;
    }

    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];

    for (var at = 0; at < 64; at++) {
      final sum1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final choice = (e & f) ^ (~e & _MASK & g);
      final temp1 = (h + sum1 + choice + _K[at] + schedule[at]) & _MASK;
      final sum0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final major = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + major) & _MASK;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _MASK;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _MASK;
    }

    hash[0] = (hash[0] + a) & _MASK;
    hash[1] = (hash[1] + b) & _MASK;
    hash[2] = (hash[2] + c) & _MASK;
    hash[3] = (hash[3] + d) & _MASK;
    hash[4] = (hash[4] + e) & _MASK;
    hash[5] = (hash[5] + f) & _MASK;
    hash[6] = (hash[6] + g) & _MASK;
    hash[7] = (hash[7] + h) & _MASK;
  }

  final out = Uint8List(32);
  for (var at = 0; at < 8; at++) {
    out[at * 4] = (hash[at] >> 24) & 0xff;
    out[at * 4 + 1] = (hash[at] >> 16) & 0xff;
    out[at * 4 + 2] = (hash[at] >> 8) & 0xff;
    out[at * 4 + 3] = hash[at] & 0xff;
  }

  return out;
}

/// HMAC-SHA256, RFC 2104, block size 64.
///
/// The argument order is (key, data), which is the order every port here
/// uses. Some standard libraries take (data, key); getting it backwards
/// produces a signature that is wrong but perfectly well-formed.
Uint8List hmacsha256(List<int> key, List<int> data) {
  var block = List<int>.from(key);

  if (64 < block.length) {
    block = List<int>.from(sha256(block));
  }
  while (block.length < 64) {
    block.add(0);
  }

  final inner = Uint8List(64 + data.length);
  final outer = Uint8List(64 + 32);

  for (var at = 0; at < 64; at++) {
    inner[at] = block[at] ^ 0x36;
    outer[at] = block[at] ^ 0x5c;
  }

  inner.setRange(64, inner.length, data);
  outer.setRange(64, outer.length, sha256(inner));

  return sha256(outer);
}

/// Lowercase hex, two digits per byte.
String hex(List<int> bytes) {
  final out = StringBuffer();

  for (final byte in bytes) {
    final value = byte & 0xff;
    out.write(_HEXDIGITS[value >> 4]);
    out.write(_HEXDIGITS[value & 0x0f]);
  }

  return out.toString();
}

const String _HEXDIGITS = '0123456789abcdef';

/// The SHA-256 of some text, as lowercase hex.
String sha256hex(String text) => hex(sha256(utf8.encode(text)));
