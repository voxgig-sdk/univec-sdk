// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/aws/sigv4.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps ten ports honest. SigV4 is a stable, published algorithm
// built from HMAC-SHA256, which the standard library already has.
//
// SigV4 is pure: the caller passes the timestamp, so the same input yields
// the same signature everywhere. That is what lets the shared spec carry
// known-answer cases that all ten ports must reproduce bit-for-bit, and
// lets the integration mock recompute the signature server-side.
//
// A port of typescript/plugins/sigv4.ts, which is canonical. It lives
// with the aws plugin because it is the one place the library needs
// HMAC-SHA256, and a built-in must not.

package aws

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"regexp"
	"sort"
	"strings"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Sigv4Input is one request to sign. The JSON tags match the shared
// spec's sigv4 group, so a spec case decodes straight into it.
type Sigv4Input struct {
	Method string `json:"method"`
	// URL is the full request URL; the host, path and query are signed.
	URL string `json:"url"`
	// Headers are extra headers to sign, e.g. content-type and
	// x-amz-target.
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
	Service string            `json:"service"`
	Region  string            `json:"region"`
	KeyID   string            `json:"keyid"`
	Secret  string            `json:"secret"`
	// Session is the STS session token; signed as x-amz-security-token
	// when present.
	Session string `json:"session"`
	// Datetime is the signing moment, YYYYMMDDTHHMMSSZ. Passed in, never
	// sampled, so the function stays pure.
	Datetime string `json:"datetime"`
}

// whitespace is one run of whitespace, collapsed to a single space in
// canonical header values.
var whitespace = regexp.MustCompile(`\s+`)

func sha256hex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func hmacsha256(key []byte, text string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(text))
	return mac.Sum(nil)
}

// percentdecode undoes percent-encoding without treating `+` as a space,
// the way the canonical port's decodeURIComponent does. A malformed
// escape is left as it came - there is nothing better to sign.
func percentdecode(text string) string {
	decoded, err := url.PathUnescape(text)
	if nil != err {
		return text
	}
	return decoded
}

// canonicalquery is the canonical query string: each pair RFC 3986-escaped,
// sorted by escaped key then escaped value.
func canonicalquery(query string) string {
	if "" == query {
		return ""
	}

	pairs := [][2]string{}
	for _, pair := range strings.Split(query, "&") {
		key := pair
		value := ""
		if eq := strings.Index(pair, "="); -1 != eq {
			key = pair[:eq]
			value = pair[eq+1:]
		}
		pairs = append(pairs, [2]string{
			httpjson.Escape(percentdecode(key)),
			httpjson.Escape(percentdecode(value)),
		})
	}

	sort.Slice(pairs, func(left, right int) bool {
		if pairs[left][0] != pairs[right][0] {
			return pairs[left][0] < pairs[right][0]
		}
		return pairs[left][1] < pairs[right][1]
	})

	parts := []string{}
	for _, pair := range pairs {
		parts = append(parts, pair[0]+"="+pair[1])
	}

	return strings.Join(parts, "&")
}

// SigV4 signs one request. It returns the headers to attach: authorization,
// x-amz-date, and x-amz-security-token when a session token was given.
func SigV4(input *Sigv4Input) (map[string]string, error) {
	parsed, err := url.Parse(input.URL)
	if nil != err {
		return nil, sekreto.Fail("sekreto: sigv4: bad url: " + input.URL)
	}

	date := input.Datetime
	if 8 < len(date) {
		date = date[:8]
	}
	body := input.Body

	// Every header that will be signed: the caller's extras, plus host and
	// x-amz-date (and the session token when present), lower-cased and
	// trimmed the way the canonical form requires.
	// Canonical header values are trimmed AND internally collapsed -
	// AWS folds sequential whitespace to one space before signing, so a
	// header like "a  b" must sign as "a b" or the service refuses it.
	headers := map[string]string{}
	for key, value := range input.Headers {
		headers[strings.ToLower(key)] = whitespace.ReplaceAllString(strings.TrimSpace(value), " ")
	}
	headers["host"] = parsed.Host
	headers["x-amz-date"] = input.Datetime
	if "" != input.Session {
		headers["x-amz-security-token"] = input.Session
	}

	names := []string{}
	for name := range headers {
		names = append(names, name)
	}
	sort.Strings(names)

	var canonicalheaders strings.Builder
	for _, name := range names {
		canonicalheaders.WriteString(name + ":" + headers[name] + "\n")
	}
	signedheaders := strings.Join(names, ";")

	path := parsed.EscapedPath()
	if "" == path {
		path = "/"
	}

	canonicalrequest := strings.Join([]string{
		strings.ToUpper(input.Method),
		path,
		canonicalquery(parsed.RawQuery),
		canonicalheaders.String(),
		signedheaders,
		sha256hex(body),
	}, "\n")

	scope := date + "/" + input.Region + "/" + input.Service + "/aws4_request"

	stringtosign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		input.Datetime,
		scope,
		sha256hex(canonicalrequest),
	}, "\n")

	kdate := hmacsha256([]byte("AWS4"+input.Secret), date)
	kregion := hmacsha256(kdate, input.Region)
	kservice := hmacsha256(kregion, input.Service)
	ksigning := hmacsha256(kservice, "aws4_request")
	signature := hex.EncodeToString(hmacsha256(ksigning, stringtosign))

	out := map[string]string{
		"authorization": "AWS4-HMAC-SHA256 Credential=" + input.KeyID + "/" + scope +
			", SignedHeaders=" + signedheaders + ", Signature=" + signature,
		"x-amz-date": input.Datetime,
	}

	if "" != input.Session {
		out["x-amz-security-token"] = input.Session
	}

	return out, nil
}
