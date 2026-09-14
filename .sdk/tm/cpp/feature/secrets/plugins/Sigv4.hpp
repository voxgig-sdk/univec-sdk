// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Sigv4.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps the ports honest. SigV4 is a stable, published algorithm
// built from HMAC-SHA256, which Crypto.cpp supplies.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases all ports reproduce bit for bit, and lets the
// integration mock recompute the signature server-side. The clock is never
// sampled here.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.

#ifndef SEKRETO_PLUGINS_SIGV4_HPP
#define SEKRETO_PLUGINS_SIGV4_HPP

#include <string>

#include "Httpjson.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

/// One request to sign - the same declarative shape the shared spec uses.
/// `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's.
struct Signing {
  std::string method;
  std::string url;
  std::string service;
  std::string region;
  std::string keyid;
  std::string secret;
  std::string datetime;
  Ordered headers;
  std::string body;
  std::string session;
};

/// SHA-256 of some text, as lowercase hex.
std::string sha256hex(const std::string& text);

/// The canonical query string: each pair decoded then RFC 3986-escaped,
/// sorted by escaped key then escaped value.
std::string canonicalquery(const std::string& query);

/// Sign one request. Returns the headers to attach: authorization,
/// x-amz-date, and x-amz-security-token when a session token was given, in
/// that order - the spec compares the result as a JSON object.
Ordered sigv4(const Signing& input);

}  // namespace sekreto

#endif
