// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Httpjson.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Just enough HTTP to ask a vault for a secret.
//
// C++ has no HTTP client in its standard library, so this speaks HTTP/1.1
// over a POSIX socket directly: a request with headers and an optional
// body, a status line, and a response body delimited by Content-Length, by
// chunks, or by the connection closing.
//
// The framing is in-tree deliberately. libcurl and cpp-httplib would both
// supply it, and both are HTTP clients rather than cryptographic transport
// - the one thing the dependency rule permits. So only the TLS half is
// bound out, and it is bound in Tls.cpp and nowhere else.
//
// It is not a general-purpose client: no redirect following, no
// keep-alive, no proxies, no client certificates. Each of those absences
// is load-bearing and the reasons are at their call sites.
//
// The shared transport of the plugins, and it is UNDER plugins/ for the
// reason the whole split exists: a chain of built-ins must never link an
// HTTP client, a TLS library or the socket beneath them.
//
// The percent-encoding and the base64 decoder live here rather than beside
// the SigV4 signer, because most of what needs them signs nothing: Azure,
// 1Password, Doppler and Infisical build query strings, and AWS and GCP
// decode payloads. Keeping them with the signer would put SHA-256 in the
// link map of every plugin that only ever speaks HTTP.
//
// A port of rust/src/http.rs.

#ifndef SEKRETO_PLUGINS_HTTPJSON_HPP
#define SEKRETO_PLUGINS_HTTPJSON_HPP

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "../sekreto/Json.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

/// How long any single round-trip may take before the store is treated as
/// unreachable. Ports carry the same bound.
extern const int TIMEOUT;

/// How much of a response body will be read before the store is treated as
/// having answered incoherently. Ports carry the same bound.
///
/// Far above anything real - the largest legitimate payload this library
/// fetches is Doppler's whole-config download, measured in kilobytes. A
/// bound is needed because the timeout is not one: ten seconds on a
/// loopback or datacentre link is gigabytes, and the body is accumulated
/// in memory before it is parsed. This runs on an application's startup
/// path, so the failure is the application never starting.
extern const size_t MAXBODY;

/// The environment variable naming extra trust roots, as a PEM bundle.
/// One cross-port spelling, so a private CA is configured the same way
/// whichever port an application uses.
extern const char* const CABUNDLE;

/// Anything a request can run over: a plain socket, or a TLS session
/// wrapping one. Failure is a thrown SekretoError; `readsome` answers 0
/// at end of stream.
class Stream {
 public:
  virtual ~Stream() = default;
  virtual size_t readsome(char* buf, size_t len) = 0;
  virtual void writeall(const char* buf, size_t len) = 0;
};

/// What a vault answered: the status code and the raw body.
struct Response {
  int status = 0;
  std::string body;
};

/// A url without its query string, for a message that must not leak one.
///
/// A query here carries the vault path, the secret name or a filter -
/// `secretPath=/prod/payments/stripe` - which belongs in neither a log nor
/// a stack trace.
std::string bareurl(const std::string& url);

/// One HTTP exchange. A non-2xx status is RETURNED, not raised: a 404 from
/// a vault means "no such secret", which is a miss rather than a failure.
/// Only a transport failure raises.
Response httprequest(const std::string& method, const std::string& url,
                     const Ordered& headers, const std::optional<std::string>& body);

/// Extract every certificate from a PEM bundle, as DER blocks.
///
/// In-tree, per the rule: the TLS exception covers transport, and reading
/// a text file is not transport. No header handling, no attributes, no
/// other label types, no private keys.
std::vector<std::string> pemcerts(const std::string& text);

/// One JSON round-trip's result: the status, and the parsed body. An
/// unparsed body is Null, which every accessor reads as "no value".
struct Answer {
  int status = 0;
  Json body;
};

/// One JSON round-trip. Network failure is always an error - an
/// unreachable store is a store that could not answer.
///
/// Redirects are never followed: a vault API does not legitimately
/// redirect, and a followed redirect would carry X-Vault-Token to a host
/// checkaddr never saw, and could downgrade https to http. Proxies are
/// never consulted: the GCP and Azure metadata endpoints are not loopback,
/// and an `http_proxy` in the environment has sent a Vault token in the
/// clear before. Httpjson.cpp does neither, so there is nothing to switch
/// off.
Answer fetchjson(const std::string& method, const std::string& url,
                 const Ordered& headers = Ordered(),
                 const std::optional<std::string>& body = std::nullopt);

/// A field's text, or nothing.
std::optional<std::string> textof(const Json& val);

/// RFC 3986 escaping, stricter than the usual URL encoder: the unreserved
/// set is exactly `A-Za-z0-9-_.~`, everything else becomes `%XX` with
/// UPPERCASE hex, byte by byte over UTF-8. `!\'()*` are escaped too, which
/// is where this differs from the encoders most standard libraries offer.
std::string uriescape(const std::string& text);

/// Percent-decode, and nothing else: `+` stays `+`, as on the wire, and a
/// malformed escape is kept literal.
std::string uridecode(const std::string& text);

/// Decode standard (not URL-safe) base64, STRICTLY.
///
/// Whitespace is stripped first; anything outside `A-Za-z0-9+/`, more than
/// two `=`, or a length that is not a multiple of four is a REFUSAL. A
/// lenient decoder skips bytes it does not know and hands back plausible
/// bytes for a corrupted payload - which then get returned as the secret.
/// Call sites: an AWS SecretBinary, a GCP payload, a PEM body.
bool unbase64(const std::string& text, std::string& out);

/// Milliseconds since the epoch. The only clock a provider reads, and it
/// is read for token renewal alone - never for a signature, which takes
/// its timestamp from its caller.
double nowms();

/// A renewal time that never comes.
extern const double NEVER;

/// When a logged-in token must be renewed, from its expiry in seconds (a
/// JSON number, or a string as Azure IMDS sends it): now + max(seconds -
/// 60, 1). A missing or zero expiry means never renew, which is also what
/// a configured token gets.
double renewtime(const Json& expires);

}  // namespace sekreto

#endif
