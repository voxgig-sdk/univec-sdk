// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/hashicorp/hashicorp.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The hashicorp plugin: HashiCorp Vault, and OpenBao. Needs HTTPS, and
// the filesystem for a kubernetes service-account JWT. A port of
// typescript/plugins/hashicorp.ts.
package hashicorp

import (
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads HashiCorp Vault.
//
// KV v2 (the default): api.token reads {addr}/v1/{mount}/data/api and takes
// the `token` field of data.data. KV v1 (KV: 1) reads {addr}/v1/{mount}/api
// and takes the field of data. A 404 means "not here", which is a miss
// rather than an error, so a vault can sit in a chain with fallbacks.
//
// A Vault Enterprise namespace rides the X-Vault-Namespace header, on
// logins as well as reads.
//
// Instead of being handed a token, the provider can log in: Kubernetes
// auth (the pod's service-account JWT, from its conventional path) or
// AppRole. A failed login is an error, never a miss - it means this store
// could not answer at all.
type Provider struct {
	Addr           string
	Token          string
	Mount          string
	KV             int
	VaultNamespace string
	Auth           *sekreto.AuthSpec
	// The working token: a configured token is kept forever, a logged-in
	// token is renewed shortly before its lease runs out - a long-running
	// process must not keep presenting a token the vault already expired.
	livetoken string
	havetoken bool
	renewat   time.Time
	mu        sync.Mutex
}

func (provider *Provider) mount() string {
	if "" == provider.Mount {
		return "secret"
	}
	return provider.Mount
}

func (provider *Provider) baseheaders() map[string]string {
	headers := map[string]string{}
	if "" != provider.VaultNamespace {
		headers["X-Vault-Namespace"] = provider.VaultNamespace
	}
	return headers
}

func (provider *Provider) login() (string, error) {
	auth := provider.Auth
	if nil == auth {
		return "", sekreto.Fail("sekreto: hashicorp: no token and no auth method")
	}

	mount := auth.Mount
	if "" == mount {
		mount = auth.Method
	}
	target := strings.TrimSuffix(provider.Addr, "/") + "/v1/auth/" + mount + "/login"

	var payload []byte
	switch auth.Method {
	case "kubernetes":
		jwt := auth.Jwt
		if "" == jwt {
			file := auth.JwtFile
			if "" == file {
				file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
			}
			raw, err := os.ReadFile(file)
			if nil != err {
				return "", sekreto.Fail("sekreto: hashicorp: cannot read jwt file " + file)
			}
			jwt = strings.TrimSpace(string(raw))
		}
		payload, _ = sekreto.WriteJSON(struct {
			Role string `json:"role"`
			Jwt  string `json:"jwt"`
		}{Role: auth.Role, Jwt: jwt})
	case "approle":
		payload, _ = sekreto.WriteJSON(struct {
			RoleID   string `json:"role_id"`
			SecretID string `json:"secret_id"`
		}{RoleID: auth.RoleID, SecretID: auth.SecretID})
	default:
		return "", sekreto.Fail("sekreto: hashicorp: unknown auth method: " + auth.Method)
	}

	status, body, err := httpjson.Call(http.MethodPost, target, provider.baseheaders(), string(payload))
	if nil != err {
		return "", err
	}

	got := httpjson.DigText(body, "auth", "client_token")
	if http.StatusOK != status || "" == got {
		return "", sekreto.Fail("sekreto: hashicorp login failed: " + strconv.Itoa(status) + ": " + target)
	}

	provider.renewat = httpjson.Expiry(httpjson.Dig(body, "auth", "lease_duration"))

	return got, nil
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	// Serialize per-provider access: Lookup reads and refreshes the cached
	// login token, and a secrets client may resolve from several goroutines.
	provider.mu.Lock()
	defer provider.mu.Unlock()

	if err := sekreto.CheckAddr(provider.Addr); nil != err {
		return "", false, err
	}

	if !provider.havetoken || httpjson.Due(provider.renewat) {
		if "" != provider.Token {
			provider.livetoken = provider.Token
		} else {
			token, err := provider.login()
			if nil != err {
				return "", false, err
			}
			provider.livetoken = token
		}
		provider.havetoken = true
	}

	ref, err := sekreto.NameVaultRef(name)
	if nil != err {
		return "", false, err
	}

	base := strings.TrimSuffix(provider.Addr, "/") + "/v1/" + provider.mount()
	target := base + "/data/" + ref.Path
	if 1 == provider.KV {
		target = base + "/" + ref.Path
	}

	headers := provider.baseheaders()
	headers["X-Vault-Token"] = provider.livetoken

	status, body, err := httpjson.Get(target, headers)
	if nil != err {
		return "", false, err
	}

	if http.StatusNotFound == status {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: hashicorp error: " + strconv.Itoa(status) + ": " + target)
	}

	var value any
	if 1 == provider.KV {
		value = httpjson.Dig(body, "data", ref.Field)
	} else {
		value = httpjson.Dig(body, "data", "data", ref.Field)
	}

	if nil == value {
		return "", false, nil
	}

	return httpjson.ToString(value), true, nil
}

func (provider *Provider) Describe() string {
	return "hashicorp:" + provider.Addr + "/" + provider.mount()
}

// Plugin is the `hashicorp` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("hashicorp", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	kv := spec.KV
	if 0 == kv {
		kv = 2
	}
	// A version typo like kv: 3 must not quietly behave as v2 and turn
	// its 404s into misses; there is nothing safe to assume it meant.
	if 1 != kv && 2 != kv {
		return nil, sekreto.Fail("sekreto: hashicorp: unsupported kv version: " + strconv.Itoa(kv))
	}
	return &Provider{
		Addr:           spec.Addr,
		Token:          spec.Token,
		Mount:          spec.Mount,
		KV:             spec.KV,
		VaultNamespace: spec.VaultNamespace,
		Auth:           spec.Auth,
	}, nil
})
