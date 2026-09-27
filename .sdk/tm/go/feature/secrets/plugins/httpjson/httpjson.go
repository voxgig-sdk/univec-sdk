// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/plugins/httpjson/httpjson.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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
	Transport: &http.Transport{Proxy: nil},
}

const maxbody = 8 * 1024 * 1024

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
		if http.StatusOK == response.StatusCode {
			return response.StatusCode, nil, sekreto.Fail("sekreto: malformed response from " +
				SafeURL(target))
		}
		body = nil
	}

	return response.StatusCode, body, nil
}

func Get(target string, headers map[string]string) (int, any, error) {
	return Call(http.MethodGet, target, headers, "")
}

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

func DigText(body any, keys ...string) string {
	value := Dig(body, keys...)
	if nil == value {
		return ""
	}
	return ToString(value)
}

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

func Due(renewat time.Time) bool {
	return !renewat.IsZero() && !time.Now().Before(renewat)
}

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
