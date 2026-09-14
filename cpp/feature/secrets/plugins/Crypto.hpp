// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Crypto.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SHA-256 and HMAC-SHA256, hand-rolled, plus hex.
//
// This port links OpenSSL, so `EVP_Digest` and `HMAC` are a function call
// away - and calling them here would break the rule that allows the link
// at all. That exception covers cryptographic TRANSPORT and nothing else:
// SigV4 is signing, not transport. Rust is the worked precedent, with
// `ring` already inside rustls's closure and `rust/src/crypto.rs` still
// carrying both primitives in-tree.
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
