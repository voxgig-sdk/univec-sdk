// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/onepassword/onepassword.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The onepassword plugin: 1Password, through a Connect server. Needs
// HTTPS. A port of typescript/plugins/onepassword.ts.
package onepassword

import (
	"net/http"
	"strconv"
	"strings"
	"sync"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads 1Password, through a Connect server.
//
// The item titled api.token (titles keep their dots), in the named vault.
// The value is the field with purpose PASSWORD, or the field labelled
// `value`. A vault that cannot be found is an error - config names it, so
// its absence is a broken store, not a missing secret.
type Provider struct {
	Addr  string
	Token string
	Vault string
	// Guards the memoised state below: a Sekreto may resolve from several
	// goroutines, and a racy map read is either a crash or a zero value - a
	// MISS where the store does hold the secret, which falls through to a
	// weaker store.
	mu        sync.Mutex
	vaultid   string
	havevault bool
}

func (provider *Provider) auth() map[string]string {
	return map[string]string{"authorization": "Bearer " + provider.Token}
}

func (provider *Provider) resolvevault(addr string) (string, error) {
	want := provider.Vault
	if "" == want {
		return "", sekreto.Fail("sekreto: onepassword: no vault")
	}

	status, body, err := httpjson.Get(addr+"/v1/vaults", provider.auth())
	if nil != err {
		return "", err
	}

	list, is := body.([]any)
	if http.StatusOK != status || !is {
		return "", sekreto.Fail("sekreto: onepassword error: " + strconv.Itoa(status) + ": listing vaults")
	}

	for _, entry := range list {
		if want == httpjson.DigText(entry, "id") || want == httpjson.DigText(entry, "name") {
			return httpjson.DigText(entry, "id"), nil
		}
	}

	return "", sekreto.Fail("sekreto: onepassword: no vault named " + want)
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	if err := sekreto.CheckName(name); nil != err {
		return "", false, err
	}

	addr := strings.TrimSuffix(provider.Addr, "/")
	if "" == addr {
		return "", false, sekreto.Fail("sekreto: onepassword: no addr")
	}
	if err := sekreto.CheckAddr(addr); nil != err {
		return "", false, err
	}

	provider.mu.Lock()
	if !provider.havevault {
		vaultid, err := provider.resolvevault(addr)
		if nil != err {
			provider.mu.Unlock()
			return "", false, err
		}
		provider.vaultid = vaultid
		provider.havevault = true
	}
	vaultid := provider.vaultid
	provider.mu.Unlock()

	filter := httpjson.Escape(`title eq "` + name + `"`)
	status, body, err := httpjson.Get(
		addr+"/v1/vaults/"+vaultid+"/items?filter="+filter, provider.auth())
	if nil != err {
		return "", false, err
	}

	found, is := body.([]any)
	if http.StatusOK != status || !is {
		return "", false, sekreto.Fail("sekreto: onepassword error: " + strconv.Itoa(status) +
			": finding " + name)
	}

	if 0 == len(found) {
		return "", false, nil
	}

	itemid := httpjson.DigText(found[0], "id")
	status, body, err = httpjson.Get(
		addr+"/v1/vaults/"+vaultid+"/items/"+itemid, provider.auth())
	if nil != err {
		return "", false, err
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: onepassword error: " + strconv.Itoa(status) +
			": reading " + name)
	}

	fields, _ := httpjson.Dig(body, "fields").([]any)

	for _, field := range fields {
		if "PASSWORD" == httpjson.DigText(field, "purpose") {
			value := httpjson.Dig(field, "value")
			if nil == value {
				return "", false, nil
			}
			return httpjson.ToString(value), true, nil
		}
	}
	for _, field := range fields {
		if "value" == httpjson.DigText(field, "label") {
			value := httpjson.Dig(field, "value")
			if nil == value {
				return "", false, nil
			}
			return httpjson.ToString(value), true, nil
		}
	}

	return "", false, nil
}

func (provider *Provider) Describe() string {
	return "onepassword:" + provider.Vault
}

// Plugin is the `onepassword` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("onepassword", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{Addr: spec.Addr, Token: spec.Token, Vault: spec.Vault}, nil
})
