// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/sekreto/addr.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package sekreto

import "strings"

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
