// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/src/Addr.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Refusing to send a secret-bearing credential in the clear.
//
// This is CORE, not plugin, even though only the plugins ever dial an
// address. The rule is sekreto's rather than any one store's, the shared
// spec pins its three messages byte for byte, and a check that ten
// plugins each carried their own copy of would drift between them - which
// is precisely how a check stops being one.
//
// A port of typescript/src/provider/addr.ts, which is canonical.

import Foundation

/// An address with any userinfo replaced by `[redacted]`, for messages.
///
/// Every refusal below names the address it refused, and one of them fires
/// precisely because the address carries a credential - so printing it
/// verbatim would write the password to stderr and into the logs. It
/// cannot be cleaned up afterwards either: that password was never
/// resolved as a secret, so redact() has never seen it and never will. The
/// host is what a reader needs to identify which chain entry is at fault;
/// the userinfo is not.
public func safeaddr(_ addr: String) -> String {
  guard let mark = addr.range(of: "://") else { return addr }

  let rest = String(addr[mark.upperBound...])
  let stop = rest.firstIndex { "/" == $0 || "?" == $0 || "#" == $0 }
  let authority = nil == stop ? rest : String(rest[rest.startIndex..<stop!])

  guard let at = authority.lastIndex(of: "@") else { return addr }

  let cut = authority.distance(from: authority.startIndex, to: at)
  let head = String(addr[addr.startIndex..<mark.upperBound])
  let tail = String(rest[rest.index(rest.startIndex, offsetBy: cut)...])

  return head + "[redacted]" + tail
}

/// Refuse to send a secret-bearing credential in the clear.
///
/// A vault API is HTTPS in any real deployment; plaintext is a dev-mode
/// convenience. Sending a token over http to anything but the local
/// machine puts both the token and the secret it fetches on the wire for
/// anyone on the path, so sekreto will not do it. Loopback stays allowed:
/// that is `vault server -dev`, `boru vault serve`, and this repo's own
/// test harness.
///
/// The address is read by hand, in the same handful of steps in every
/// port, rather than by each platform's URL parser. That is deliberate. A
/// dozen parsers disagree about malformed input - where userinfo ends,
/// whether `0177.0.0.1` is loopback, what an unclosed bracket means - and
/// a check that answers differently in different ports is not a check.
///
/// The rule this parse obeys, and the reason it can be trusted: it is
/// never more permissive than the HTTP client that will dial the address.
/// It ends the authority at `/`, `?` or `#` only, so a client that also
/// breaks on `\` (WHATWG does) can only ever see a SHORTER host than this
/// does. It refuses userinfo outright rather than locating its end. It
/// compares the host literally, so a numeric form no parser here agrees on
/// is refused rather than guessed at.
public func checkaddr(_ addr: String) throws {
  var scheme = ""

  // Literal and case-sensitive: `HTTP://localhost` is refused rather than
  // normalised, because normalising is where parsers start to disagree.
  if addr.hasPrefix("https://") {
    scheme = "https://"
  } else if addr.hasPrefix("http://") {
    scheme = "http://"
  } else {
    throw SekretoError("sekreto: not an http(s) address: \(safeaddr(addr))")
  }

  let rest = String(addr.dropFirst(scheme.count))
  let end = rest.firstIndex { "/" == $0 || "?" == $0 || "#" == $0 }
  let authority = nil == end ? rest : String(rest[rest.startIndex..<end!])

  // Userinfo is refused outright rather than parsed around, and on https
  // as well as http. No store this library speaks authenticates by
  // userinfo - they take a token or a signature - so an address carrying
  // one is a mistake at best. At worst it is the attack this whole
  // function exists to stop: `http://localhost:8200@evil.example.com/` is
  // a request to evil.example.com that reads, to anything that splits the
  // authority on ':', as loopback.
  if authority.contains("@") {
    throw SekretoError(
      "sekreto: refusing an address with embedded credentials: \(safeaddr(addr))")
  }

  // An opening bracket with no closing one is not an address at all.
  if authority.hasPrefix("[") && !authority.contains("]") {
    throw SekretoError("sekreto: not a valid http(s) address: \(safeaddr(addr))")
  }

  if "https://" == scheme { return }

  // A bracketed IPv6 literal keeps its brackets. Splitting the authority
  // on the first colon yields '[', so `http://[::1]:8200` could never
  // match - which made the '[::1]' entry below unreachable, and refused a
  // legitimate local vault.
  var host = authority

  if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
    host = String(authority[authority.startIndex...close])
  } else if let colon = authority.firstIndex(of: ":") {
    host = String(authority[authority.startIndex..<colon])
  }

  host = asciilower(host)

  // Literal, and exactly these four. Nothing is normalised: `0177.0.0.1`,
  // `2130706433` and `[::ffff:127.0.0.1]` are all refused, because no two
  // URL parsers agree on what they mean.
  if "localhost" != host && "127.0.0.1" != host && "::1" != host && "[::1]" != host {
    throw SekretoError(
      "sekreto: refusing to send a token in plaintext to \(safeaddr(addr)) (use https)")
  }
}
