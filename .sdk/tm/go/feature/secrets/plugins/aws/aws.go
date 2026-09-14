// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/aws/aws.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The aws plugin: Secrets Manager and SSM Parameter Store, with requests
// SigV4-signed in-tree (sigv4.go, beside this file). Needs HTTPS and
// HMAC-SHA256 - the one cryptographic dependency in the library, which is
// why this is a plugin and why the core never imports crypto. A port of
// typescript/plugins/aws.ts.
package aws

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// awsnow is the YYYYMMDDTHHMMSSZ timestamp SigV4 wants, for now.
func awsnow() string {
	return time.Now().UTC().Format("20060102T150405Z")
}

// awscreds is a resolved set of AWS credentials.
type awscreds struct {
	region  string
	keyid   string
	secret  string
	session string
}

// awsauth resolves region and credentials, from config first and the
// standard AWS_* environment variables second - those are AWS's own
// convention, and a pod or CI job that has them set should just work.
// Missing either is an error: an AWS store with no credentials could not
// answer.
func awsauth(region string, keyid string, secret string, session string) (*awscreds, error) {
	if "" == region {
		region = os.Getenv("AWS_REGION")
	}
	if "" == region {
		region = os.Getenv("AWS_DEFAULT_REGION")
	}
	if "" == keyid {
		keyid = os.Getenv("AWS_ACCESS_KEY_ID")
	}
	if "" == secret {
		secret = os.Getenv("AWS_SECRET_ACCESS_KEY")
	}
	if "" == session {
		session = os.Getenv("AWS_SESSION_TOKEN")
	}

	if "" == region {
		return nil, sekreto.Fail("sekreto: aws: no region (set region or AWS_REGION)")
	}
	if "" == keyid || "" == secret {
		return nil, sekreto.Fail("sekreto: aws: no credentials (set keyid/secret or " +
			"AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)")
	}

	return &awscreds{region: region, keyid: keyid, secret: secret, session: session}, nil
}

// awscall makes one signed call to an AWS JSON-1.1 API.
func awscall(
	region string, keyid string, secret string, session string, addr string,
	service string, target string, payload string,
) (int, any, error) {
	auth, err := awsauth(region, keyid, secret, session)
	if nil != err {
		return 0, nil, err
	}

	if "" == addr {
		// The China partition lives under its own suffix; every other
		// commercial region is plain amazonaws.com.
		suffix := ".amazonaws.com"
		if strings.HasPrefix(auth.region, "cn-") {
			suffix = ".amazonaws.com.cn"
		}
		addr = "https://" + service + "." + auth.region + suffix
	}
	if err := sekreto.CheckAddr(addr); nil != err {
		return 0, nil, err
	}

	requrl := strings.TrimSuffix(addr, "/") + "/"
	headers := map[string]string{
		"content-type": "application/x-amz-json-1.1",
		"x-amz-target": target,
	}

	signed, err := SigV4(&Sigv4Input{
		Method:   http.MethodPost,
		URL:      requrl,
		Headers:  headers,
		Body:     payload,
		Service:  service,
		Region:   auth.region,
		KeyID:    auth.keyid,
		Secret:   auth.secret,
		Session:  auth.session,
		Datetime: awsnow(),
	})
	if nil != err {
		return 0, nil, err
	}

	for key, value := range signed {
		headers[key] = value
	}

	return httpjson.Call(http.MethodPost, requrl, headers, payload)
}

// awsmiss reports whether this AWS error body names one of the not-found
// types. Those are a miss; every other failure is a store that could not
// answer.
func awsmiss(body any, types []string) bool {
	errtype, _ := httpjson.Dig(body, "__type").(string)

	for _, name := range types {
		if strings.Contains(errtype, name) {
			return true
		}
	}

	return false
}

// SecretsProvider reads AWS Secrets Manager.
//
// api.token reads the secret named `api` (the vaultref path, so
// db.pass.main reads db/pass) and takes the `token` field of its JSON
// SecretString - the AWS idiom of one JSON map per secret. A SecretString
// that is not JSON is the value itself, under the conventional field
// `value`. Requests are SigV4-signed in-tree; see sigv4.go.
type SecretsProvider struct {
	Region  string
	KeyID   string
	Secret  string
	Session string
	Addr    string
}

func (provider *SecretsProvider) Lookup(name string) (string, bool, error) {
	ref, err := sekreto.NameVaultRef(name)
	if nil != err {
		return "", false, err
	}

	payload, _ := sekreto.WriteJSON(struct {
		SecretID string `json:"SecretId"`
	}{SecretID: ref.Path})

	status, body, err := awscall(
		provider.Region, provider.KeyID, provider.Secret, provider.Session, provider.Addr,
		"secretsmanager", "secretsmanager.GetSecretValue", string(payload))
	if nil != err {
		return "", false, err
	}

	if http.StatusBadRequest == status && awsmiss(body, []string{"ResourceNotFoundException"}) {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: aws secretsmanager error: " + strconv.Itoa(status))
	}

	text, is := httpjson.Dig(body, "SecretString").(string)

	if !is {
		// A binary secret has no fields to address; only the conventional
		// `value` field can mean "the bytes themselves".
		bin, is := httpjson.Dig(body, "SecretBinary").(string)
		if is && "value" == ref.Field {
			// The error was discarded, so a corrupted payload decoded to
			// whatever came before the bad byte and was returned as the
			// secret. A store that answered incoherently is an error.
			decoded, err := base64.StdEncoding.DecodeString(bin)
			if nil != err {
				return "", false, sekreto.Fail("sekreto: aws secretsmanager: undecodable secret")
			}
			return string(decoded), true, nil
		}
		return "", false, nil
	}

	var parsed map[string]any
	if err := json.Unmarshal([]byte(text), &parsed); nil == err && nil != parsed {
		value, has := parsed[ref.Field]
		if !has || nil == value {
			return "", false, nil
		}
		return httpjson.ToString(value), true, nil
	}

	// A plain-string secret is the whole value; it has no named fields.
	if "value" == ref.Field {
		return text, true, nil
	}

	return "", false, nil
}

// Config only, never the environment: Describe feeds the spec's sources
// group, which must answer the same everywhere.
func (provider *SecretsProvider) Describe() string {
	return "awssecrets:" + provider.Region
}

// ParamsProvider reads AWS SSM Parameter Store.
//
// db.pass.main reads the parameter /db/pass/main (under an optional prefix
// path), decrypted. Parameter Store carries flat strings, so there is no
// field indirection.
type ParamsProvider struct {
	Region  string
	KeyID   string
	Secret  string
	Session string
	Addr    string
	Prefix  string
}

func (provider *ParamsProvider) Lookup(name string) (string, bool, error) {
	param, err := sekreto.AwsParam(name, provider.Prefix)
	if nil != err {
		return "", false, err
	}

	payload, _ := sekreto.WriteJSON(struct {
		Name           string `json:"Name"`
		WithDecryption bool   `json:"WithDecryption"`
	}{Name: param, WithDecryption: true})

	status, body, err := awscall(
		provider.Region, provider.KeyID, provider.Secret, provider.Session, provider.Addr,
		"ssm", "AmazonSSM.GetParameter", string(payload))
	if nil != err {
		return "", false, err
	}

	if http.StatusBadRequest == status && awsmiss(body, []string{"ParameterNotFound"}) {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: aws ssm error: " + strconv.Itoa(status))
	}

	value := httpjson.Dig(body, "Parameter", "Value")
	if nil == value {
		return "", false, nil
	}

	return httpjson.ToString(value), true, nil
}

func (provider *ParamsProvider) Describe() string {
	return "awsparams:" + provider.Region + provider.Prefix
}

// Secrets is the `awssecrets` provider kind, as a voxgig/plugin definition.
var Secrets = sekreto.ProviderPlugin("awssecrets", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &SecretsProvider{
		Region:  spec.Region,
		KeyID:   spec.KeyID,
		Secret:  spec.Secret,
		Session: spec.Session,
		Addr:    spec.Addr,
	}, nil
})

// Params is the `awsparams` provider kind, as a voxgig/plugin definition.
var Params = sekreto.ProviderPlugin("awsparams", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &ParamsProvider{
		Region:  spec.Region,
		KeyID:   spec.KeyID,
		Secret:  spec.Secret,
		Session: spec.Session,
		Addr:    spec.Addr,
		Prefix:  spec.Prefix,
	}, nil
})
