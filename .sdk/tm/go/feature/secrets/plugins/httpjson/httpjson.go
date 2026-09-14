// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/httpjson/httpjson.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The HTTP half of every plugin that speaks to a store over the wire, in
// one place and OUTSIDE the core: a chain of built-ins never links this
// package, which is what keeps `net/http` out of a binary whose secrets
// come from the environment and a .env file.
//
// One JSON round-trip, bounded in time and in size, refusing redirects and
// ignoring proxies; and the small helpers every store client needs to read
// a decoded body. A port of typescript/plugins/httpjson.ts.
package httpjson

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"GOMODULE/feature/secrets/sekreto"
)

// A vault API never legitimately redirects, and a followed redirect would
// carry X-Vault-Token to the redirect's host (and could downgrade https to
// http) - checkaddr only validates the configured address, so it cannot
// see the target. Refuse to follow one.
var client = &http.Client{
	Timeout: 10 * time.Second,
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	},
	// A secrets client dials the address it was configured with and nowhere
	// else. http.DefaultTransport reads HTTP_PROXY; its resolver exempts
	// loopback, so the local dev vault was never exposed - but the GCP and
	// Azure metadata endpoints are not loopback, and the access tokens they
	// return would have gone through whatever the variable named, which can
	// read them and substitute its own.
	Transport: &http.Transport{Proxy: nil},
}

// maxbody is how much of a response body will be read before the store is
// treated as having answered incoherently. Ports carry the same bound.
//
// Far above anything real - the largest legitimate payload this library
// fetches is Doppler's whole-config download, measured in kilobytes. A bound
// is needed because the TIMEOUT is not one: ten seconds on a loopback or
// datacentre link is gigabytes, and the body is accumulated in memory before
// it is parsed. This runs on an application's startup path, so the failure is
// the application never starting.
const maxbody = 8 * 1024 * 1024

// SafeURL is a url with its query string removed, for messages.
//
// A query here carries the vault path, the secret name or a filter -
// `secretPath=/prod/payments/stripe` - which does not belong in a log or a
// stack trace. Every message in this file goes through it.
//
// It exists because the obvious spelling was silently defeated: the messages
// used to strip the query themselves and then append err.Error(), and a
// *url.Error prints as `Get "<full url>": <reason>` - putting the query
// straight back. Stripping in one place, and using it on the wrapped error
// too, is what makes the intent hold.
func SafeURL(target string) string {
	return strings.SplitN(target, "?", 2)[0]
}

// Call makes one JSON round-trip, returning the status and decoded
// body. Network failure is always an error - an unreachable store is a
// store that could not answer.
func Call(method string, target string, headers map[string]string, payload string) (int, any, error) {
	var reader io.Reader
	if "" != payload {
		reader = strings.NewReader(payload)
	}

	request, err := http.NewRequest(method, target, reader)
	if nil != err {
		return 0, nil, sekreto.Fail("sekreto: bad url: " + SafeURL(target))
	}

	for key, value := range headers {
		request.Header.Set(key, value)
	}

	response, err := client.Do(request)
	if nil != err {
		// The error is scrubbed too, not just the prefix: *url.Error prints
		// as `Get "<full url>": <reason>`, so appending it verbatim undid
		// the stripping on the line above.
		return 0, nil, sekreto.Fail("sekreto: cannot reach " + SafeURL(target) + ": " +
			strings.ReplaceAll(err.Error(), target, SafeURL(target)))
	}
	defer response.Body.Close()

	// LimitReader, not ReadAll: an endless body would otherwise be
	// accumulated in memory until the deadline, which on a loopback or
	// datacentre link is gigabytes. One byte over the bound is enough to
	// know it was exceeded.
	text, err := io.ReadAll(io.LimitReader(response.Body, maxbody+1))
	if nil != err {
		return response.StatusCode, nil, sekreto.Fail("sekreto: cannot read " + SafeURL(target))
	}
	if maxbody < int64(len(text)) {
		return response.StatusCode, nil, sekreto.Fail("sekreto: oversized response from " + SafeURL(target))
	}

	var body any
	if err := json.Unmarshal(text, &body); nil != err {
		// A success status promised JSON; a body that does not parse means
		// the store could not answer coherently, and treating it as a miss
		// would fall through to a weaker store. Error statuses may carry
		// any body - they are decided on status alone.
		if http.StatusOK == response.StatusCode {
			return response.StatusCode, nil, sekreto.Fail("sekreto: malformed response from " +
				SafeURL(target))
		}
		body = nil
	}

	return response.StatusCode, body, nil
}

// Get GETs a URL, returning the status and decoded body. A 404 is a
// normal answer here, not a failure: it means the vault has no such secret.
func Get(target string, headers map[string]string) (int, any, error) {
	return Call(http.MethodGet, target, headers, "")
}

// Dig walks a decoded JSON body by key, answering nil as soon as a step is
// not an object or the key is absent.
func Dig(body any, keys ...string) any {
	node := body

	for _, key := range keys {
		object, is := node.(map[string]any)
		if !is {
			return nil
		}
		node = object[key]
	}

	return node
}

// DigText is Dig rendered as text, with nil (and so any missing step)
// answering the empty string.
func DigText(body any, keys ...string) string {
	value := Dig(body, keys...)
	if nil == value {
		return ""
	}
	return ToString(value)
}

// ToNumber reads a decoded JSON value as a number the way the canonical
// port's Number() does: numbers pass through, numeric strings parse
// (Azure's IMDS hands expires_in back as a string), and anything else -
// missing, malformed - is zero.
func ToNumber(value any) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case string:
		number, err := strconv.ParseFloat(typed, 64)
		if nil != err {
			return 0
		}
		return number
	default:
		return 0
	}
}

// Expiry is the moment a login token should be renewed: shortly before
// its lifetime (in seconds, from the login response) runs out. A missing
// or zero lifetime answers the zero time, which means never renew.
func Expiry(lifetime any) time.Time {
	seconds := ToNumber(lifetime)
	if 0 >= seconds {
		return time.Time{}
	}

	wait := seconds - 60
	if 1 > wait {
		wait = 1
	}

	return time.Now().Add(time.Duration(wait * float64(time.Second)))
}

// Due reports whether a renewal moment has arrived; the zero time never
// arrives.
func Due(renewat time.Time) bool {
	return !renewat.IsZero() && !time.Now().Before(renewat)
}

// ToString renders a decoded JSON scalar the way the canonical port's
// String() does.
func ToString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case bool:
		return strconv.FormatBool(typed)
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	default:
		text, err := sekreto.WriteJSON(typed)
		if nil != err {
			return ""
		}
		return string(text)
	}
}

// Escape is RFC 3986 escaping, which is stricter than most standard
// escapers: everything but the unreserved characters is escaped, with
// uppercase hex - `!`, `'`, `(`, `)` and `*` included. It is what AWS
// signing wants, and what the canonical port's encodeURIComponent-built
// query strings decode identically from.
func Escape(text string) string {
	const hexdigit = "0123456789ABCDEF"

	var out strings.Builder

	for _, char := range []byte(text) {
		if 'A' <= char && 'Z' >= char || 'a' <= char && 'z' >= char ||
			'0' <= char && '9' >= char ||
			'-' == char || '_' == char || '.' == char || '~' == char {
			out.WriteByte(char)
		} else {
			out.WriteByte('%')
			out.WriteByte(hexdigit[char>>4])
			out.WriteByte(hexdigit[char&0xf])
		}
	}

	return out.String()
}
