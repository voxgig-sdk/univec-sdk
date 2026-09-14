// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Tls.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The TLS binding, and the only file in this port that names OpenSSL.
//
// AGENTS.md rule 3 as a principle: cryptographic transport is not
// hand-rolled. Where a port's standard library has TLS it uses it; where
// it does not, it binds the platform's audited TLS library - the same one
// that language's own ecosystem binds. For C++ that is OpenSSL, reached
// directly rather than through Boost.Asio's SSL stream or cpp-httplib,
// because those bring an HTTP framing the rule requires in-tree.
//
// Audit surface: `-lssl -lcrypto`, and the distribution's OpenSSL is the
// audit surface. Nothing else is linked. Note in particular that
// libcrypto's own digests are NOT used for SigV4 - the exception covers
// transport only, so Crypto.cpp carries SHA-256 and HMAC in-tree, exactly
// as rust/src/crypto.rs does beside rustls.

#ifndef SEKRETO_PLUGINS_TLS_HPP
#define SEKRETO_PLUGINS_TLS_HPP

#include <memory>
#include <string>

#include "Httpjson.hpp"

namespace sekreto {

/// Hand a connected socket to OpenSSL and complete the handshake.
///
/// `host` is the BARE host - an IPv6 literal without its brackets - and is
/// what the certificate is checked against. Four obligations, all met
/// before any byte of the request is written, and all in Tls.cpp:
///
///   1. the chain is verified against the system trust store;
///   2. the HOSTNAME is verified, which is a separate step from the chain;
///   3. SNI is sent, except for an IP literal, which RFC 6066 forbids;
///   4. SEKRETO_CA_BUNDLE adds extra roots, additively.
///
/// A handshake failure is a refusal to trust the server, so it surfaces as
/// an error and never as a missing secret. Ownership of `fd` passes to the
/// returned stream.
std::unique_ptr<Stream> tlsstream(int fd, const std::string& host, const std::string& url);

}  // namespace sekreto

#endif
