-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Crypto.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
SHA-256 and HMAC-SHA256, hand-rolled.

A PLUGIN MODULE, AND THE ONLY ONE THAT HASHES ANYTHING. The core of no
port imports a hash function: SigV4 is the one thing in this library that
needs a digest, so the digest lives beside it, inside the aws plugin, and
a chain of built-ins links neither.

Lean's standard library has no cryptographic primitives at all, and the
rule that lets this port bind libcurl covers CRYPTOGRAPHIC TRANSPORT and
nothing else: calling into the OpenSSL that libcurl already links, for a
digest, would be reaching through the exception rather than living within
it. So these are in-tree, as they are in the rust port for the same
reason.

Correctness is not argued here, it is proved: SigV4 is a chain of exactly
these two primitives, and `spec/sekreto.json` carries five known-answer
signatures - one of them AWS's own published `get-vanilla` vector. One
wrong bit anywhere below fails there.

A port of rust/plugins/aws/src/crypto.rs.
-/

import Sekreto.Text

namespace Sekreto

/-- The sixty-four round constants: the first thirty-two bits of the
fractional parts of the cube roots of the first sixty-four primes
(FIPS 180-4). -/
private def SHAK : Array UInt32 := #[
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
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

/-- The eight initial hash words: the fractional parts of the square
roots of the first eight primes. -/
private def SHAH : Array UInt32 := #[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

private def rotr (value : UInt32) (by_ : UInt32) : UInt32 :=
  (value >>> by_) ||| (value <<< (32 - by_))

/-- The four bytes at `pos`, big-endian. -/
private def be32 (bytes : ByteArray) (pos : Nat) : UInt32 :=
  ((bytes.get! pos).toUInt32 <<< 24) |||
  ((bytes.get! (pos + 1)).toUInt32 <<< 16) |||
  ((bytes.get! (pos + 2)).toUInt32 <<< 8) |||
  (bytes.get! (pos + 3)).toUInt32

private def pushbe32 (out : ByteArray) (word : UInt32) : ByteArray :=
  ((out.push (word >>> 24).toUInt8).push (word >>> 16).toUInt8).push (word >>> 8).toUInt8
    |>.push word.toUInt8

/-- FIPS 180-4 padding: `0x80`, zeros to 56 mod 64, then the message
length in BITS as a big-endian 64-bit count. -/
private def shapad (size : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty.push 0x80
  for _ in [0 : (56 + 64 - ((size + 1) % 64)) % 64] do
    out := out.push 0
  let bits := size * 8
  for shift in [0:8] do
    out := out.push (UInt8.ofNat ((bits >>> (8 * (7 - shift))) % 256))
  return out

/-- SHA-256 of `data`, thirty-two bytes. -/
def sha256 (data : ByteArray) : ByteArray := Id.run do
  let message := data ++ shapad data.size
  let mut state := SHAH

  for block in [0 : message.size / 64] do
    let base := block * 64

    -- The message schedule: sixteen words from the block, forty-eight
    -- derived from them.
    let mut w : Array UInt32 := Array.mkEmpty 64
    for slot in [0:16] do
      w := w.push (be32 message (base + slot * 4))
    for slot in [16:64] do
      let a := w[slot - 15]!
      let b := w[slot - 2]!
      let s0 := (rotr a 7) ^^^ (rotr a 18) ^^^ (a >>> 3)
      let s1 := (rotr b 17) ^^^ (rotr b 19) ^^^ (b >>> 10)
      w := w.push (w[slot - 16]! + s0 + w[slot - 7]! + s1)

    let mut a := state[0]!
    let mut b := state[1]!
    let mut c := state[2]!
    let mut d := state[3]!
    let mut e := state[4]!
    let mut f := state[5]!
    let mut g := state[6]!
    let mut h := state[7]!

    for round in [0:64] do
      let big1 := (rotr e 6) ^^^ (rotr e 11) ^^^ (rotr e 25)
      let ch := (e &&& f) ^^^ ((~~~e) &&& g)
      let t1 := h + big1 + ch + SHAK[round]! + w[round]!
      let big0 := (rotr a 2) ^^^ (rotr a 13) ^^^ (rotr a 22)
      let maj := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)
      let t2 := big0 + maj
      h := g; g := f; f := e; e := d + t1
      d := c; c := b; b := a; a := t1 + t2

    state := #[state[0]! + a, state[1]! + b, state[2]! + c, state[3]! + d,
               state[4]! + e, state[5]! + f, state[6]! + g, state[7]! + h]

  return state.foldl pushbe32 ByteArray.empty

/-- SHA-256 of the UTF-8 bytes of `text`, as lowercase hex. -/
def sha256hex (text : String) : String := hexlower (sha256 text.toUTF8)

private def BLOCKSIZE : Nat := 64

private def xorpad (key : ByteArray) (pad : UInt8) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  for slot in [0:BLOCKSIZE] do
    let byte := if slot < key.size then key.get! slot else 0
    out := out.push (byte ^^^ pad)
  return out

/-- HMAC-SHA256, RFC 2104: a key longer than the block is hashed down, a
shorter one is zero-padded up.

The argument order is `(key, data)` everywhere in this repository. Some
standard libraries take `(data, key)`; the convention is fixed here so no
call site has to remember which. -/
def hmacsha256 (key data : ByteArray) : ByteArray :=
  let short := if BLOCKSIZE < key.size then sha256 key else key
  sha256 (xorpad short 0x5c ++ sha256 (xorpad short 0x36 ++ data))

/-- HMAC-SHA256 with a text message, which is every call site here. -/
def hmac (key : ByteArray) (text : String) : ByteArray := hmacsha256 key text.toUTF8

end Sekreto
