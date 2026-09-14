// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/infisical/infisical.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The infisical plugin: Infisical. Needs HTTPS. A port of
// typescript/plugins/infisical.ts.
package infisical

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads Infisical.
//
// api.token reads the secret keyed API_TOKEN (Infisical's own convention
// is environment-style keys) at a secret path in one environment of a
// project. Auth is a token, or a universal-auth (machine identity) login
// with clientid/clientsecret.
type Provider struct {
	Addr         string
	Token        string
	ClientID     string
	ClientSecret string
	Project      string
	Environment  string
	Path         string
	// A configured token is kept forever; a universal-auth token carries
	// expiresIn and is renewed shortly before it runs out.
	livetoken string
	havetoken bool
	renewat   time.Time
	mu        sync.Mutex
}

func (provider *Provider) login(addr string) (string, error) {
	if "" != provider.Token {
		return provider.Token, nil
	}

	if "" == provider.ClientID || "" == provider.ClientSecret {
		return "", sekreto.Fail("sekreto: infisical: no token and no client credentials")
	}

	payload, _ := sekreto.WriteJSON(struct {
		ClientID     string `json:"clientId"`
		ClientSecret string `json:"clientSecret"`
	}{ClientID: provider.ClientID, ClientSecret: provider.ClientSecret})

	status, body, err := httpjson.Call(http.MethodPost, addr+"/api/v1/auth/universal-auth/login",
		map[string]string{"content-type": "application/json"}, string(payload))
	if nil != err {
		return "", err
	}

	got := httpjson.DigText(body, "accessToken")
	if http.StatusOK != status || "" == got {
		return "", sekreto.Fail("sekreto: infisical login failed: " + strconv.Itoa(status))
	}

	provider.renewat = httpjson.Expiry(httpjson.Dig(body, "expiresIn"))

	return got, nil
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	// Serialize per-provider access: Lookup reads and refreshes the cached
	// login token, and a secrets client may resolve from several goroutines.
	provider.mu.Lock()
	defer provider.mu.Unlock()

	addr := provider.Addr
	if "" == addr {
		addr = "https://app.infisical.com"
	}
	addr = strings.TrimSuffix(addr, "/")
	if err := sekreto.CheckAddr(addr); nil != err {
		return "", false, err
	}

	if "" == provider.Project || "" == provider.Environment {
		return "", false, sekreto.Fail("sekreto: infisical: no project/environment")
	}

	if !provider.havetoken || httpjson.Due(provider.renewat) {
		token, err := provider.login(addr)
		if nil != err {
			return "", false, err
		}
		provider.livetoken = token
		provider.havetoken = true
	}

	key, err := sekreto.EnvKey(name, "")
	if nil != err {
		return "", false, err
	}

	path := provider.Path
	if "" == path {
		path = "/"
	}
	target := addr + "/api/v3/secrets/raw/" + key +
		"?workspaceId=" + httpjson.Escape(provider.Project) +
		"&environment=" + httpjson.Escape(provider.Environment) +
		"&secretPath=" + httpjson.Escape(path)

	status, body, err := httpjson.Get(target,
		map[string]string{"authorization": "Bearer " + provider.livetoken})
	if nil != err {
		return "", false, err
	}

	if http.StatusNotFound == status {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: infisical error: " + strconv.Itoa(status))
	}

	value := httpjson.Dig(body, "secret", "secretValue")
	if nil == value {
		return "", false, nil
	}

	return httpjson.ToString(value), true, nil
}

func (provider *Provider) Describe() string {
	return "infisical:" + provider.Project + "/" + provider.Environment
}

// Plugin is the `infisical` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("infisical", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{
		Addr:         spec.Addr,
		Token:        spec.Token,
		ClientID:     spec.ClientID,
		ClientSecret: spec.ClientSecret,
		Project:      spec.Project,
		Environment:  spec.Environment,
		Path:         spec.Path,
	}, nil
})
