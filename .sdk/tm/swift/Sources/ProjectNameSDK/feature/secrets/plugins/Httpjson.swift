// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Httpjson.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The shared HTTP-JSON round-trip, and the small helpers every remote
// store needs.
//
// Bounded, redirect-refusing and proxy-ignoring. It lives under plugins/
// and not in the core because a chain of built-in kinds must never link a
// socket: the four built-ins read at most a local file, and this is the
// first thing on the other side of that line.
//
// A port of typescript/plugins/httpjson.ts, which is canonical.

import Dispatch
import Foundation

import Sekreto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// How long any single vault round-trip may take before it is treated as
/// unreachable. Ports carry the same bound.
let TIMEOUT: Double = 10

/// How much of a response body will be read before the store is treated as
/// having answered incoherently. Ports carry the same bound.
///
/// Far above anything real - the largest legitimate payload this library
/// fetches is Doppler's whole-config download, measured in kilobytes. A
/// bound is needed because the timeout is not one: ten seconds on a
/// loopback or datacentre link is gigabytes, and the body is accumulated
/// in memory before it is parsed. This runs on an application's startup
/// path, so the failure is the application never starting.
let MAXBODY: Int = 8 * 1024 * 1024

/// An environment variable, or nil.
///
/// The core has one of these too, and one `dropsuffix`. They are three
/// lines each, and publishing them from the core instead would put a
/// `getenv` into every consumer's namespace beside the C one it shadows.
/// A module boundary costs something, and this is the whole bill.
func getenv(_ name: String) -> String? {
  return ProcessInfo.processInfo.environment[name]
}

func dropsuffix(_ text: String, _ suffix: String) -> String {
  return text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
}

func trimslash(_ text: String) -> String {
  return dropsuffix(text, "/")
}

/// A URL without its query string, for a message that must not leak one.
func bare(_ url: String) -> String {
  if let mark = url.firstIndex(of: "?") {
    return String(url[url.startIndex..<mark])
  }
  return url
}

/// One JSON round-trip's result: the status, and the parsed body.
struct Answer {
  let status: Int
  let body: Json?
}

/// The delegate that makes one round-trip behave.
///
/// Redirects are never followed: a vault API does not legitimately
/// redirect, and a followed redirect would carry X-Vault-Token to the
/// redirect's host (and could downgrade https to http), which checkaddr -
/// it only validates the configured address - cannot see. Answering the
/// completion handler with nil hands the redirect response itself back as
/// the result, which the caller then reads as the non-200 it is.
///
/// The body is counted as it arrives and the task cancelled one byte over
/// the bound, so an endless body is refused rather than accumulated in
/// memory until the deadline.
final class Roundtrip: NSObject, URLSessionDataDelegate {

  var status: Int = 0
  var data = Data()
  var oversize = false
  var failure: Error?

  let finished = DispatchSemaphore(value: 0)

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse {
      status = http.statusCode
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    if oversize { return }

    data.append(chunk)

    if MAXBODY < data.count {
      oversize = true
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    status = response.statusCode
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    failure = error
    finished.signal()
  }
}

/// One JSON round-trip. Network failure is always an error - an
/// unreachable store is a store that could not answer.
func fetchjson(
  _ method: String,
  _ url: String,
  _ headers: Ordered<String> = Ordered<String>(),
  _ body: String? = nil
) throws -> Answer {
  guard let target = URL(string: url) else {
    throw SekretoError("sekreto: cannot reach \(bare(url)): not a usable address")
  }

  var request = URLRequest(url: target)
  request.httpMethod = method
  request.timeoutInterval = TIMEOUT

  for (key, value) in headers.pairs {
    request.setValue(value, forHTTPHeaderField: key)
  }

  if let text = body {
    request.httpBody = Data(text.utf8)
  }

  let config = URLSessionConfiguration.default
  config.timeoutIntervalForRequest = TIMEOUT
  config.timeoutIntervalForResource = TIMEOUT
  config.httpShouldSetCookies = false
  config.urlCache = nil
  config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
  // A proxy in the environment has sent a Vault token in the clear before,
  // and the GCP and Azure metadata endpoints are not loopback.
  config.connectionProxyDictionary = [:]

  let trip = Roundtrip()
  let session = URLSession(configuration: config, delegate: trip, delegateQueue: nil)

  session.dataTask(with: request).resume()
  trip.finished.wait()
  session.invalidateAndCancel()

  // One byte over the bound is enough to know it was exceeded. An endless
  // body is a store that could not answer, so this raises rather than
  // returning a miss - the latter would fall through to a weaker store on
  // an attacker's cue.
  if trip.oversize {
    throw SekretoError("sekreto: oversized response from \(bare(url))")
  }

  if let failure = trip.failure {
    throw SekretoError("sekreto: cannot reach \(bare(url)): \(why(failure))")
  }

  let text = String(decoding: trip.data, as: UTF8.self)
  let parsed = Json.parse(text)

  // A success status promised JSON; a body that does not parse means the
  // store could not answer coherently, and treating it as a miss would
  // fall through to a weaker store. Error statuses may carry any body -
  // they are decided on status alone.
  if 200 == trip.status && nil == parsed {
    throw SekretoError("sekreto: malformed response from \(bare(url))")
  }

  return Answer(status: trip.status, body: parsed)
}

/// When a logged-in token must be renewed, from its expiry in seconds (a
/// JSON number, or a string as Azure IMDS sends it): now + max(seconds -
/// 60, 1). A missing or zero expiry means never renew.
func renewtime(_ expires: Json?) -> Double {
  var seconds: Double = 0

  if let value = expires?.asnum {
    seconds = value
  } else if let text = expires?.asstr, let value = Double(text) {
    seconds = value
  }

  if seconds.isNaN || 0 >= seconds { return Double.greatestFiniteMagnitude }

  return nowms() + max(seconds - 60, 1) * 1000
}

func nowms() -> Double {
  return Date().timeIntervalSince1970 * 1000
}

// -------------------------------------------------------------- base64

// Decoding a store's answer, not signing a request: GCP Secret Manager and
// Azure Key Vault both hand back base64, and neither needs a hash. It sits
// here rather than in Crypto.swift so that a chain naming one of them
// compiles no SHA-256 - which is the same reason Crypto.swift is not in the
// core.

/// Decode standard base64, strictly.
///
/// Strict on purpose: a lenient decoder skips bytes outside the alphabet
/// and hands back plausible bytes for a corrupted payload, which are then
/// returned as the secret. Whitespace is stripped first because the
/// canonical function accepts embedded newlines - a PEM body or a wrapped
/// AWS SecretBinary - and everything else is refused.
public func unbase64(_ text: String) -> String? {
  var clean = ""

  for ch in text.unicodeScalars {
    if " " == ch || "\n" == ch || "\r" == ch || "\t" == ch { continue }
    clean.unicodeScalars.append(ch)
  }

  let chars = Array(clean.utf8)
  if 0 != chars.count % 4 { return nil }

  var padding = 0
  var body = chars

  while 0 < body.count, 0x3d == body[body.count - 1] {  // '='
    padding += 1
    body.removeLast()
    if 2 < padding { return nil }
  }

  var accumulator: UInt32 = 0
  var bits = 0
  var out: [UInt8] = []

  for byte in body {
    guard let sextet = b64value(byte) else { return nil }
    accumulator = (accumulator << 6) | UInt32(sextet)
    bits += 6

    if 8 <= bits {
      bits -= 8
      out.append(UInt8((accumulator >> UInt32(bits)) & 0xff))
    }
  }

  return String(decoding: out, as: UTF8.self)
}

private func b64value(_ byte: UInt8) -> UInt8? {
  switch byte {
  case 0x41...0x5a: return byte - 0x41  // A-Z
  case 0x61...0x7a: return byte - 0x61 + 26  // a-z
  case 0x30...0x39: return byte - 0x30 + 52  // 0-9
  case 0x2b: return 62  // +
  case 0x2f: return 63  // /
  default: return nil
  }
}

// ------------------------------------------------------ percent-encoding

// Here rather than in Sigv4.swift, where it started, because four of the
// HTTP plugins need it and only one of them signs anything: a chain naming
// Azure Key Vault should not compile request signing to get an escaped
// query parameter. `make lean` is what found it.

/// RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
/// wants everything but unreserved characters escaped, with uppercase hex.
/// `!'()*` are escaped too, which is where this differs from the encoders
/// most standard libraries offer.
public func uriescape(_ text: String) -> String {
  var out = ""

  for byte in Array(text.utf8) {
    let ch = Character(Unicode.Scalar(byte))

    if ("A" <= ch && "Z" >= ch) || ("a" <= ch && "z" >= ch) || ("0" <= ch && "9" >= ch)
      || "-" == ch || "_" == ch || "." == ch || "~" == ch
    {
      out.append(ch)
    } else {
      out += String(format: "%%%02X", byte)
    }
  }

  return out
}
