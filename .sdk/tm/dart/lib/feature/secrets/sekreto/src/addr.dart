// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/src/addr.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// What sekreto will and will not dial.
//
// IN THE CORE, though no built-in kind opens a socket. `checkaddr` is the
// rule that decides whether a token may be sent to an address at all, and a
// rule the plugins each carried a copy of would be ten rules. It is pure
// string work - nothing here connects to anything - so the core keeps it
// and every plugin that speaks HTTP imports it.
//
// A port of typescript/src/provider/addr.ts, which is canonical.

import 'sekreto.dart';

/// The index of the first character of [chars], or -1.
int stopat(String text, String chars) {
  for (var at = 0; at < text.length; at++) {
    if (chars.contains(text[at])) {
      return at;
    }
  }
  return -1;
}

/// An address with any userinfo replaced by `[redacted]`, for messages.
///
/// Every refusal below names the address it refused, and one of them fires
/// precisely because the address carries a credential - so printing it
/// verbatim would write the password to stderr and into the logs. It cannot
/// be cleaned up afterwards either: that password was never resolved as a
/// secret, so redact() has never seen it and never will. The host is what a
/// reader needs to identify which chain entry is at fault; the userinfo is
/// not.
String safeaddr(String addr) {
  final mark = addr.indexOf('://');
  if (-1 == mark) {
    return addr;
  }

  final rest = addr.substring(mark + 3);
  final stop = stopat(rest, '/?#');
  final authority = -1 == stop ? rest : rest.substring(0, stop);

  final at = authority.lastIndexOf('@');
  if (-1 == at) {
    return addr;
  }

  return '${addr.substring(0, mark + 3)}[redacted]${addr.substring(mark + 3 + at)}';
}

/// Refuse to send a secret-bearing credential in the clear.
///
/// A vault API is HTTPS in any real deployment; plaintext is a dev-mode
/// convenience. Sending a token over http to anything but the local machine
/// puts both the token and the secret it fetches on the wire for anyone on
/// the path, so sekreto will not do it. Loopback stays allowed: that is
/// `vault server -dev`, `boru vault serve`, and this repo's own test
/// harness.
///
/// The address is read by hand, in the same handful of steps in every port,
/// rather than by `Uri.parse`. That is deliberate. A dozen parsers disagree
/// about malformed input - where userinfo ends, whether `0177.0.0.1` is
/// loopback, what an unclosed bracket means - and a check that answers
/// differently in different ports is not a check.
///
/// The rule this parse obeys, and the reason it can be trusted: it is never
/// more permissive than the HTTP client that will dial the address. It ends
/// the authority at `/`, `?` or `#` only, so a client that also breaks on
/// `\` (WHATWG does) can only ever see a SHORTER host than this does. It
/// refuses userinfo outright rather than locating its end. It compares the
/// host literally, so a numeric form no parser here agrees on is refused
/// rather than guessed at.
void checkaddr(String addr) {
  final String scheme;

  if (addr.startsWith('https://')) {
    scheme = 'https://';
  } else if (addr.startsWith('http://')) {
    scheme = 'http://';
  } else {
    throw SekretoError('sekreto: not an http(s) address: ${safeaddr(addr)}');
  }

  final rest = addr.substring(scheme.length);
  final end = stopat(rest, '/?#');
  final authority = -1 == end ? rest : rest.substring(0, end);

  // Userinfo is refused outright rather than parsed around, and on https as
  // well as http. No store this library speaks authenticates by userinfo -
  // they take a token or a signature - so an address carrying one is a
  // mistake at best. At worst it is the attack this whole function exists to
  // stop: `http://localhost:8200@evil.example.com/` is a request to
  // evil.example.com that reads, to anything that splits the authority on
  // ':', as loopback.
  if (authority.contains('@')) {
    throw SekretoError(
      'sekreto: refusing an address with embedded credentials: ${safeaddr(addr)}',
    );
  }

  // An opening bracket with no closing one is not an address at all.
  if (authority.startsWith('[') && !authority.contains(']')) {
    throw SekretoError(
      'sekreto: not a valid http(s) address: ${safeaddr(addr)}',
    );
  }

  if ('https://' == scheme) {
    return;
  }

  // A bracketed IPv6 literal keeps its brackets. Splitting the authority on
  // the first colon yields '[', so `http://[::1]:8200` could never match -
  // which would make the '[::1]' entry below unreachable, and refuse a
  // legitimate local vault.
  final String host;
  if (authority.startsWith('[')) {
    host = authority.substring(0, authority.indexOf(']') + 1).toLowerCase();
  } else {
    final colon = authority.indexOf(':');
    host = (-1 == colon ? authority : authority.substring(0, colon))
        .toLowerCase();
  }

  // Literal, and exactly four. Nothing is normalised: `0177.0.0.1`,
  // `2130706433` and `[::ffff:127.0.0.1]` are loopback to some resolvers and
  // not to others, and a check that has to guess is not a check.
  if ('localhost' != host &&
      '127.0.0.1' != host &&
      '::1' != host &&
      '[::1]' != host) {
    throw SekretoError(
      'sekreto: refusing to send a token in plaintext to ${safeaddr(addr)} (use https)',
    );
  }
}
