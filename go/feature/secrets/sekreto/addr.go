// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/sekreto/addr.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The plaintext-address guard, in the core because it is pure - a
// handful of string steps, no socket - and because it is on the spec:
// every port answers the same for every address in spec/def/store.aon.
// The plugins that dial an address call CheckAddr before they do.
//
// A port of typescript/src/provider/addr.ts.

package sekreto

import "strings"

// SafeAddr returns the address with any userinfo replaced by [redacted],
// for messages.
//
// Every refusal in CheckAddr names the address it refused, and one of them fires
// precisely because the address carries a credential - so printing it
// verbatim wrote the password to stderr and into the logs. It cannot be
// cleaned up afterwards either: that password was never resolved as a
// secret, so Redact has never seen it and never will. The host is what a
// reader needs to identify which chain entry is at fault; the userinfo is
// not.
func SafeAddr(addr string) string {
	mark := strings.Index(addr, "://")
	if -1 == mark {
		return addr
	}

	rest := addr[mark+3:]
	authority := rest
	if end := strings.IndexAny(rest, "/?#"); -1 != end {
		authority = rest[:end]
	}

	at := strings.LastIndex(authority, "@")
	if -1 == at {
		return addr
	}

	return addr[:mark+3] + "[redacted]" + addr[mark+3+at:]
}

// CheckAddr refuses to send a Vault token in the clear.
//
// Vault's API is HTTPS in any real deployment; plaintext is a dev-mode
// convenience. Sending X-Vault-Token over http to anything but the local
// machine puts both the token and the secret it fetches on the wire for
// anyone on the path, so sekreto will not do it. Loopback stays allowed:
// that is `vault server -dev` and this repo's own test harness.
//
// The address is read by hand, in the same handful of steps in every port,
// rather than by each platform's URL parser. That is deliberate. Twelve
// parsers disagree about malformed input - where userinfo ends, whether
// 0177.0.0.1 is loopback, what an unclosed bracket means - and a check that
// answers differently in different ports is not a check.
//
// The rule this parse obeys, and the reason it can be trusted: it is never
// more permissive than the HTTP client that will dial the address. It ends
// the authority at '/', '?' or '#' only, so a client that also breaks on
// '\' (WHATWG does) can only ever see a SHORTER host than this does. It
// refuses userinfo outright rather than locating its end. It compares the
// host literally, so a numeric form no parser here agrees on is refused
// rather than guessed at.
func CheckAddr(addr string) error {
	scheme := ""
	if strings.HasPrefix(addr, "https://") {
		scheme = "https://"
	} else if strings.HasPrefix(addr, "http://") {
		scheme = "http://"
	} else {
		return Fail("sekreto: not an http(s) address: " + SafeAddr(addr))
	}

	rest := addr[len(scheme):]
	end := strings.IndexAny(rest, "/?#")
	authority := rest
	if -1 != end {
		authority = rest[:end]
	}

	// Userinfo is refused outright rather than parsed around, and on https as
	// well as http. No store this library speaks authenticates by userinfo -
	// they take a token or a signature - so an address carrying one is a
	// mistake at best. At worst it is the attack this whole function exists
	// to stop: http://localhost:8200@evil.example.com/ is a request to
	// evil.example.com that reads, to anything that splits the authority on
	// ':', as loopback.
	if strings.Contains(authority, "@") {
		return Fail("sekreto: refusing an address with embedded credentials: " + SafeAddr(addr))
	}

	// An opening bracket with no closing one is not an address at all.
	if strings.HasPrefix(authority, "[") && !strings.Contains(authority, "]") {
		return Fail("sekreto: not a valid http(s) address: " + SafeAddr(addr))
	}

	if "https://" == scheme {
		return nil
	}

	// A bracketed IPv6 literal keeps its brackets. Splitting the authority on
	// the first colon yields "[", so http://[::1]:8200 could never match -
	// which made the "[::1]" entry below unreachable, and refused a
	// legitimate local vault.
	host := authority
	if strings.HasPrefix(authority, "[") {
		host = authority[:strings.Index(authority, "]")+1]
	} else {
		host = strings.Split(authority, ":")[0]
	}

	switch strings.ToLower(host) {
	case "localhost", "127.0.0.1", "::1", "[::1]":
		return nil
	}

	return Fail("sekreto: refusing to send a token in plaintext to " + SafeAddr(addr) + " (use https)")
}
