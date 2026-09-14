// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Crypto.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SHA-256 and HMAC-SHA256, hand-rolled.
//
// Swift has no hashing in its standard library, and the two obvious
// answers are both closed to this port: CryptoKit ships only on Apple
// platforms, and swift-crypto is a package. Both primitives are small,
// published and stable, so they are written here.
//
// The rule that allows a TLS binding (cryptographic transport is not
// hand-rolled) does not reach these: SigV4 is signing, not transport.
// Foundation reaches libcurl and therefore an audited TLS library for
// HTTPS; calling into that library's digests for a signature would be the
// same rule violation the Rust port avoids by keeping crypto.rs in-tree.
//
// Correctness is not asserted here - it is proved by the SigV4
// known-answer vectors in the shared spec. A signature is a chain of these
// two functions, so one wrong bit anywhere fails there.
//
// IT LIVES UNDER plugins/ AND NOT IN THE CORE. The core of no port
// imports a hash function: sigv4 is the sharpest instance of the
// core/plugin line, and it moved here with the aws plugin
// (docs/design/plugin-providers.md).
//
// A port of rust/src/crypto.rs.

import Foundation

/// FIPS 180-4 round constants: the first 32 bits of the fractional parts
/// of the cube roots of the first 64 primes.
private let K: [UInt32] = [
  0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
  0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
  0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
  0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
  0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
  0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
  0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
  0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
  0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
  0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
  0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
  0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
  0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
  0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
  0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
  0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
]

/// The eight initial hash words: the first 32 bits of the fractional parts
/// of the square roots of the first 8 primes.
private let H0: [UInt32] = [
  0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
  0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
]

@inline(__always)
private func ror(_ word: UInt32, _ bits: UInt32) -> UInt32 {
  return (word >> bits) | (word << (32 - bits))
}

/// SHA-256 of some bytes, as 32 bytes.
public func sha256(_ data: [UInt8]) -> [UInt8] {
  var message = data

  // Padding: one 0x80 byte, zeros up to 56 mod 64, then the message length
  // in BITS as a big-endian 64-bit integer.
  let bitlen = UInt64(data.count) &* 8
  message.append(0x80)
  while 56 != message.count % 64 {
    message.append(0)
  }
  for shift in stride(from: 56, through: 0, by: -8) {
    message.append(UInt8truncating(bitlen >> UInt64(shift)))
  }

  var hash = H0

  var block = 0
  while block < message.count {
    var schedule = [UInt32](repeating: 0, count: 64)

    for index in 0..<16 {
      let at = block + index * 4
      schedule[index] =
        (UInt32(message[at]) << 24) | (UInt32(message[at + 1]) << 16)
        | (UInt32(message[at + 2]) << 8) | UInt32(message[at + 3])
    }

    for index in 16..<64 {
      let prev15 = schedule[index - 15]
      let prev2 = schedule[index - 2]
      let sigma0 = ror(prev15, 7) ^ ror(prev15, 18) ^ (prev15 >> 3)
      let sigma1 = ror(prev2, 17) ^ ror(prev2, 19) ^ (prev2 >> 10)
      schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
    }

    var a = hash[0]
    var b = hash[1]
    var c = hash[2]
    var d = hash[3]
    var e = hash[4]
    var f = hash[5]
    var g = hash[6]
    var h = hash[7]

    for index in 0..<64 {
      let bigsigma1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)
      let choose = (e & f) ^ (~e & g)
      let temp1 = h &+ bigsigma1 &+ choose &+ K[index] &+ schedule[index]
      let bigsigma0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)
      let major = (a & b) ^ (a & c) ^ (b & c)
      let temp2 = bigsigma0 &+ major

      h = g
      g = f
      f = e
      e = d &+ temp1
      d = c
      c = b
      b = a
      a = temp1 &+ temp2
    }

    hash[0] = hash[0] &+ a
    hash[1] = hash[1] &+ b
    hash[2] = hash[2] &+ c
    hash[3] = hash[3] &+ d
    hash[4] = hash[4] &+ e
    hash[5] = hash[5] &+ f
    hash[6] = hash[6] &+ g
    hash[7] = hash[7] &+ h

    block += 64
  }

  var out: [UInt8] = []
  out.reserveCapacity(32)
  for word in hash {
    out.append(UInt8truncating(UInt64(word) >> 24))
    out.append(UInt8truncating(UInt64(word) >> 16))
    out.append(UInt8truncating(UInt64(word) >> 8))
    out.append(UInt8truncating(UInt64(word)))
  }

  return out
}

@inline(__always)
private func UInt8truncating(_ value: UInt64) -> UInt8 {
  return UInt8(value & 0xff)
}

/// HMAC-SHA256, RFC 2104, block size 64.
///
/// The argument order is `(key, data)` everywhere in this repository. Some
/// standard libraries take `(data, key)`; the order is fixed here so no
/// call site has to remember which.
public func hmacsha256(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
  var usekey = key

  if 64 < usekey.count {
    usekey = sha256(usekey)
  }
  while usekey.count < 64 {
    usekey.append(0)
  }

  var inner: [UInt8] = []
  var outer: [UInt8] = []
  inner.reserveCapacity(64 + data.count)
  outer.reserveCapacity(96)

  for byte in usekey {
    inner.append(byte ^ 0x36)
    outer.append(byte ^ 0x5c)
  }

  inner.append(contentsOf: data)
  outer.append(contentsOf: sha256(inner))

  return sha256(outer)
}

/// Lowercase, zero-padded hex.
public func hex(_ bytes: [UInt8]) -> String {
  let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
  var out = ""
  out.reserveCapacity(bytes.count * 2)

  for byte in bytes {
    out.append(digits[Int(byte >> 4)])
    out.append(digits[Int(byte & 0x0f)])
  }

  return out
}
