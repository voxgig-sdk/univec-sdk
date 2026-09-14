// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/doppler/doppler.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The doppler plugin: Doppler, one bulk download per config. Needs
// HTTPS. A port of typescript/plugins/doppler.ts.
package doppler

import (
	"net/http"
	"strconv"
	"strings"
	"sync"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads Doppler.
//
// The whole config is downloaded once - Doppler's own bulk endpoint - and
// answered from memory, like a remote .env: api.token is the API_TOKEN
// entry. A service token is config-scoped, so project and config are only
// needed with broader tokens.
type Provider struct {
	Token   string
	Project string
	Config  string
	Addr    string
	// Guards the memoised state below: a Sekreto may resolve from several
	// goroutines, and a racy map read is either a crash or a zero value - a
	// MISS where the store does hold the secret, which falls through to a
	// weaker store.
	mu     sync.Mutex
	values map[string]string
}

func (provider *Provider) load() (map[string]string, error) {
	provider.mu.Lock()
	defer provider.mu.Unlock()

	if nil != provider.values {
		return provider.values, nil
	}

	addr := provider.Addr
	if "" == addr {
		addr = "https://api.doppler.com"
	}
	addr = strings.TrimSuffix(addr, "/")
	if err := sekreto.CheckAddr(addr); nil != err {
		return nil, err
	}

	target := addr + "/v3/configs/config/secrets/download?format=json"
	if "" != provider.Project {
		target += "&project=" + httpjson.Escape(provider.Project)
	}
	if "" != provider.Config {
		target += "&config=" + httpjson.Escape(provider.Config)
	}

	status, body, err := httpjson.Get(target,
		map[string]string{"authorization": "Bearer " + provider.Token})
	if nil != err {
		return nil, err
	}

	object, is := body.(map[string]any)
	if http.StatusOK != status || !is {
		return nil, sekreto.Fail("sekreto: doppler error: " + strconv.Itoa(status))
	}

	values := map[string]string{}
	for key, value := range object {
		if nil != value {
			values[key] = httpjson.ToString(value)
		}
	}
	provider.values = values

	return values, nil
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	key, err := sekreto.EnvKey(name, "")
	if nil != err {
		return "", false, err
	}

	values, err := provider.load()
	if nil != err {
		return "", false, err
	}

	value, has := values[key]
	return value, has, nil
}

func (provider *Provider) Describe() string {
	if "" != provider.Project {
		return "doppler:" + provider.Project + "/" + provider.Config
	}
	return "doppler"
}

// Plugin is the `doppler` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("doppler", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{
		Token:   spec.Token,
		Project: spec.Project,
		Config:  spec.Config,
		Addr:    spec.Addr,
	}, nil
})
