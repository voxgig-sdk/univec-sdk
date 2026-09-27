// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/plugins/aws/sigv4.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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
	Method  string            `json:"method"`
	URL     string            `json:"url"`
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
