// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (cpp/plugins/Crypto.hpp)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SHA-256 and HMAC-SHA256, hand-rolled, plus hex.
//
// This port links OpenSSL, so `EVP_Digest` and `HMAC` are a function call
// away. These two are written out anyway, and AGENTS.md's dependency rule
// now says so outright rather than by omission: the exception used to
// cover cryptographic TRANSPORT and nothing else, and it now covers
// cryptography, because `Minivault.cpp` needs a block cipher to protect
// secrets at rest and a table-driven AES passes every known-answer test
// in the world while still handing its key to anyone who can time a
// cache. These stay because they work and cost nothing to keep.
//
// Correctness is not asserted here - it is proved by the SigV4
// known-answer vectors in the shared spec. A signature is a chain of these
// two functions, so one wrong bit anywhere fails there.
//
// A port of rust/src/crypto.rs.

// NOTHING BUT THE SIGNER INCLUDES THIS. Percent-encoding and base64 used
// to sit here; they moved to Httpjson.hpp, because the plugins that need
// them - Azure, 1Password, Doppler, Infisical, GCP - sign nothing, and
// including this file for a query string would put SHA-256 into their link
// maps.

#ifndef SEKRETO_PLUGINS_CRYPTO_HPP
#define SEKRETO_PLUGINS_CRYPTO_HPP

#include <cstdint>
#include <string>
#include <vector>

namespace sekreto {

using Bytes = std::vector<uint8_t>;

Bytes tobytes(const std::string& text);
std::string frombytes(const Bytes& data);

/// SHA-256 of some bytes, as 32 bytes.
Bytes sha256(const Bytes& data);

/// HMAC-SHA256, RFC 2104, block size 64. Argument order is (key, data);
/// PHP's and Perl's stdlib take (data, key), and the wrapper is where that
/// gets fixed, never at the call sites.
Bytes hmacsha256(const Bytes& key, const Bytes& data);

/// Lowercase, zero-padded, two digits a byte.
std::string hex(const Bytes& data);

}  // namespace sekreto

#endif
