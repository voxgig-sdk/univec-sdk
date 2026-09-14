// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/src/com/voxgig/sekreto/Addr.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Reading a vault address, and refusing the ones that would leak.
//
// Core, not a plugin: nothing here opens anything. It is the check every
// plugin that DOES open a socket runs first, so it has to be reachable
// from a place that reaches no plugin.
//
// A port of typescript/src/provider/addr.ts, which is canonical.

package JAVAPACKAGE.feature.secrets.sekreto;

import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;

public final class Addr {

  private Addr() {}

  /**
   * An address with any userinfo replaced by `[redacted]`, for messages.
   *
   * <p>Every refusal below names the address it refused, and one of them
   * fires precisely because the address carries a credential - so printing it
   * verbatim wrote the password to stderr and into the logs. It cannot be
   * cleaned up afterwards either: that password was never resolved as a
   * secret, so redact() has never seen it and never will. The host is what a
   * reader needs to identify which chain entry is at fault; the userinfo is
   * not.
   */
  public static String safeaddr(String addr) {
    int mark = addr.indexOf("://");
    if (-1 == mark) {
      return addr;
    }

    String rest = addr.substring(mark + 3);
    int end = rest.length();
    for (String mark2 : new String[] {"/", "?", "#"}) {
      int found = rest.indexOf(mark2);
      if (-1 != found && found < end) {
        end = found;
      }
    }

    int at = rest.substring(0, end).lastIndexOf('@');
    if (-1 == at) {
      return addr;
    }

    return addr.substring(0, mark + 3) + "[redacted]" + addr.substring(mark + 3 + at);
  }

  /**
   * Refuse to send a secret-bearing credential in the clear.
   *
   * <p>A vault API is HTTPS in any real deployment; plaintext is a dev-mode
   * convenience. Sending a token over http to anything but the local machine
   * puts both the token and the secret it fetches on the wire for anyone on
   * the path, so sekreto will not do it. Loopback stays allowed: that is
   * `vault server -dev`, `boru vault serve`, and this repo's own test
   * harness.
   *
   * <p>The address is read by hand, in the same handful of steps in every
   * port, rather than by each platform's URL parser. That is deliberate.
   * Twelve parsers disagree about malformed input - where userinfo ends,
   * whether `0177.0.0.1` is loopback, what an unclosed bracket means - and a
   * check that answers differently in different ports is not a check.
   *
   * <p>The rule this parse obeys, and the reason it can be trusted: it is
   * never more permissive than the HTTP client that will dial the address. It
   * ends the authority at `/`, `?` or `#` only, so a client that also breaks
   * on `\` (WHATWG does) can only ever see a SHORTER host than this does. It
   * refuses userinfo outright rather than locating its end. It compares the
   * host literally, so a numeric form no parser here agrees on is refused
   * rather than guessed at.
   */
  public static void checkaddr(String addr) {
    String scheme;
    if (addr.startsWith("https://")) {
      scheme = "https://";
    } else if (addr.startsWith("http://")) {
      scheme = "http://";
    } else {
      throw new SekretoError("sekreto: not an http(s) address: " + safeaddr(addr));
    }

    String rest = addr.substring(scheme.length());

    int end = rest.length();
    for (String mark : new String[] {"/", "?", "#"}) {
      int at = rest.indexOf(mark);
      if (-1 != at && at < end) {
        end = at;
      }
    }
    String authority = rest.substring(0, end);

    // Userinfo is refused outright rather than parsed around, and on https as
    // well as http. No store this library speaks authenticates by userinfo -
    // they take a token or a signature - so an address carrying one is a
    // mistake at best. At worst it is the attack this whole function exists
    // to stop: http://localhost:8200@evil.example.com/ is a request to
    // evil.example.com that reads, to anything that splits the authority on
    // ':', as loopback.
    if (authority.contains("@")) {
      throw new SekretoError("sekreto: refusing an address with embedded credentials: " + safeaddr(addr));
    }

    // An opening bracket with no closing one is not an address at all.
    if (authority.startsWith("[") && !authority.contains("]")) {
      throw new SekretoError("sekreto: not a valid http(s) address: " + safeaddr(addr));
    }

    if ("https://".equals(scheme)) {
      return;
    }

    // A bracketed IPv6 literal keeps its brackets. Splitting the authority on
    // the first colon yields "[", so http://[::1]:8200 could never match -
    // which made the "[::1]" entry below unreachable, and refused a
    // legitimate local vault.
    String host;
    if (authority.startsWith("[")) {
      host = authority.substring(0, authority.indexOf("]") + 1);
    } else {
      int colon = authority.indexOf(':');
      host = -1 == colon ? authority : authority.substring(0, colon);
    }
    host = host.toLowerCase(java.util.Locale.ROOT);

    if ("localhost".equals(host)
        || "127.0.0.1".equals(host)
        || "::1".equals(host)
        || "[::1]".equals(host)) {
      return;
    }

    throw new SekretoError(
        "sekreto: refusing to send a token in plaintext to " + safeaddr(addr) + " (use https)");
  }
}
