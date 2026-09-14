// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Sigv4.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps the ports honest. SigV4 is a stable, published algorithm
// built from HMAC-SHA256, which Crypto.swift supplies.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all ports must reproduce bit-for-bit, and
// lets the integration mock recompute the signature server-side.
//
// It travels with the aws plugin, not with the core: signing a request is
// what makes a kind a plugin (docs/design/plugin-providers.md).
//
// A port of typescript/src/Sigv4.ts, which is canonical.

import Foundation

import Sekreto

/// One request to sign - the same declarative shape the shared spec uses.
/// `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's, so that
/// signing is a pure function of its input.
public struct Signing {

  public var method: String
  public var url: String
  public var service: String
  public var region: String
  public var keyid: String
  public var secret: String
  public var datetime: String
  public var headers: Ordered<String>
  public var body: String
  public var session: String?

  public init(
    method: String,
    url: String,
    service: String,
    region: String,
    keyid: String,
    secret: String,
    datetime: String,
    headers: Ordered<String> = Ordered<String>(),
    body: String = "",
    session: String? = nil
  ) {
    self.method = method
    self.url = url
    self.service = service
    self.region = region
    self.keyid = keyid
    self.secret = secret
    self.datetime = datetime
    self.headers = headers
    self.body = body
    self.session = session
  }
}

/// SHA-256 of some text, as lowercase hex.
public func sha256hex(_ text: String) -> String {
  return hex(sha256(Array(text.utf8)))
}

/// HMAC-SHA256 of some text under a key.
public func hmac(_ key: [UInt8], _ text: String) -> [UInt8] {
  return hmacsha256(key, Array(text.utf8))
}


/// Percent-decode, and nothing else: `+` stays `+`, as on the wire, and a
/// malformed escape is kept literal.
public func uridecode(_ text: String) -> String {
  let chars = Array(text.utf8)
  var out: [UInt8] = []
  var index = 0

  while index < chars.count {
    var taken = false

    if 0x25 == chars[index], index + 2 < chars.count {  // '%'
      let digits = String(decoding: chars[(index + 1)...(index + 2)], as: UTF8.self)
      if let code = UInt8(digits, radix: 16) {
        out.append(code)
        index += 3
        taken = true
      }
    }

    if !taken {
      out.append(chars[index])
      index += 1
    }
  }

  return String(decoding: out, as: UTF8.self)
}

/// The canonical query string: each pair RFC 3986-escaped, sorted by
/// escaped key then escaped value.
public func canonicalquery(_ query: String) -> String {
  if query.isEmpty { return "" }

  var pairs: [(String, String)] = []

  for pair in query.components(separatedBy: "&") {
    let split = pair.firstIndex(of: "=")
    let key = nil == split ? pair : String(pair[pair.startIndex..<split!])
    let value = nil == split ? "" : String(pair[pair.index(after: split!)...])
    pairs.append((uriescape(uridecode(key)), uriescape(uridecode(value))))
  }

  pairs.sort { left, right in
    if left.0 != right.0 { return left.0 < right.0 }
    return left.1 < right.1
  }

  return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
}

/// A URL, split by hand.
///
/// Not URLComponents: what SigV4 signs must match what the address check
/// saw and what the client will dial, and a platform URL type is free to
/// normalise any of the three differently. `host` follows the WHATWG rule
/// the AWS SDKs use - lowercased, userinfo stripped, the port present only
/// when it is not the scheme's default.
struct Urlparts {
  var scheme: String
  var host: String
  var path: String
  var query: String
}

func urlparts(_ url: String) -> Urlparts {
  var scheme = ""
  var rest = url

  if let mark = url.range(of: "://") {
    scheme = String(url[url.startIndex..<mark.lowerBound]).lowercased()
    rest = String(url[mark.upperBound...])
  }

  var authority = rest
  var tail = ""

  if let stop = rest.firstIndex(where: { "/" == $0 || "?" == $0 || "#" == $0 }) {
    authority = String(rest[rest.startIndex..<stop])
    tail = String(rest[stop...])
  }

  // Userinfo is not part of the host, and never part of a signature.
  if let at = authority.lastIndex(of: "@") {
    authority = String(authority[authority.index(after: at)...])
  }

  var hostname = authority
  var port = ""

  if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
    hostname = String(authority[authority.startIndex...close])
    let after = String(authority[authority.index(after: close)...])
    if after.hasPrefix(":") { port = String(after.dropFirst()) }
  } else if let colon = authority.lastIndex(of: ":") {
    hostname = String(authority[authority.startIndex..<colon])
    port = String(authority[authority.index(after: colon)...])
  }

  hostname = asciilower(hostname)

  // A default port is implicit: `Host: example.com:443` is not what an AWS
  // SDK signs, and a signature over the wrong host is refused.
  if ("https" == scheme && "443" == port) || ("http" == scheme && "80" == port) {
    port = ""
  }

  var path = "/"
  var query = ""

  if !tail.isEmpty {
    var pathpart = tail

    if let hash = tail.firstIndex(of: "#") {
      pathpart = String(tail[tail.startIndex..<hash])
    }

    if let mark = pathpart.firstIndex(of: "?") {
      query = String(pathpart[pathpart.index(after: mark)...])
      pathpart = String(pathpart[pathpart.startIndex..<mark])
    }

    if !pathpart.isEmpty { path = pathpart }
  }

  return Urlparts(
    scheme: scheme,
    host: port.isEmpty ? hostname : hostname + ":" + port,
    path: path,
    query: query
  )
}

/// Trim, and collapse every internal run of spaces and tabs to one space.
///
/// AWS folds sequential whitespace before signing, so a header value like
/// `a  b\tc` must sign as `a b c` or the service refuses the request.
func foldspace(_ text: String) -> String {
  var out = ""
  var pending = false
  var started = false

  for ch in text {
    if " " == ch || "\t" == ch || "\n" == ch || "\r" == ch {
      if started { pending = true }
      continue
    }
    if pending {
      out.append(" ")
      pending = false
    }
    out.append(ch)
    started = true
  }

  return out
}

/// Sign one request. Returns the headers to attach: authorization,
/// x-amz-date, and x-amz-security-token when a session token was given, in
/// that order - the spec compares the result as a JSON object, and callers
/// print it field by field.
public func sigv4(_ input: Signing) -> Ordered<String> {
  let parts = urlparts(input.url)

  let date = String(input.datetime.prefix(8))
  let session = (input.session?.isEmpty ?? true) ? nil : input.session

  // Every header that will be signed: the caller's extras, plus host and
  // x-amz-date (and the session token when present). The built-in three go
  // in AFTER the caller's, so they win over anything passed in.
  var headers = Ordered<String>()

  for (key, value) in input.headers.pairs {
    headers[asciilower(key)] = foldspace(value)
  }

  headers["host"] = parts.host
  headers["x-amz-date"] = input.datetime
  if let token = session { headers["x-amz-security-token"] = token }

  let sorted = headers.pairs.sorted { $0.0 < $1.0 }

  let canonicalheaders = sorted.map { "\($0.0):\($0.1)\n" }.joined()
  let signedheaders = sorted.map { $0.0 }.joined(separator: ";")

  let canonicalrequest = [
    asciiupper(input.method),
    parts.path,
    canonicalquery(parts.query),
    canonicalheaders,
    signedheaders,
    sha256hex(input.body),
  ].joined(separator: "\n")

  let scope = "\(date)/\(input.region)/\(input.service)/aws4_request"

  let stringtosign = [
    "AWS4-HMAC-SHA256",
    input.datetime,
    scope,
    sha256hex(canonicalrequest),
  ].joined(separator: "\n")

  let kdate = hmac(Array(("AWS4" + input.secret).utf8), date)
  let kregion = hmac(kdate, input.region)
  let kservice = hmac(kregion, input.service)
  let ksigning = hmac(kservice, "aws4_request")
  let signature = hex(hmac(ksigning, stringtosign))

  var out = Ordered<String>()

  out["authorization"] =
    "AWS4-HMAC-SHA256 Credential=\(input.keyid)/\(scope)"
    + ", SignedHeaders=\(signedheaders)"
    + ", Signature=\(signature)"
  out["x-amz-date"] = input.datetime

  if let token = session { out["x-amz-security-token"] = token }

  return out
}
