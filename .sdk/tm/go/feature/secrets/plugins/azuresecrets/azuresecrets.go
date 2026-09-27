// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/plugins/azuresecrets/azuresecrets.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The azuresecrets plugin: Azure Key Vault. Needs HTTPS. A port of
// typescript/plugins/azuresecrets.ts.
package azuresecrets

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// azureresource is the audience Azure Key Vault tokens are scoped to.
const azureresource = "https://vault.azure.net"

type Provider struct {
	Vault        string
	Token        string
	Tenant       string
	ClientID     string
	ClientSecret string
	LoginAddr    string
	ImdsAddr     string
	ApiVersion   string
	// A configured token is kept forever; logged-in and IMDS tokens carry
	// expires_in and are renewed shortly before they run out.
	livetoken string
	havetoken bool
	renewat   time.Time
	mu        sync.Mutex
}

func (provider *Provider) login() (string, error) {
	if "" != provider.Token {
		return provider.Token, nil
	}

	if "" != provider.Tenant && "" != provider.ClientID && "" != provider.ClientSecret {
		loginaddr := provider.LoginAddr
		if "" == loginaddr {
			loginaddr = "https://login.microsoftonline.com"
		}
		if err := sekreto.CheckAddr(loginaddr); nil != err {
			return "", err
		}

		target := strings.TrimSuffix(loginaddr, "/") + "/" + provider.Tenant +
			"/oauth2/v2.0/token"
		form := "grant_type=client_credentials&client_id=" + httpjson.Escape(provider.ClientID) +
			"&client_secret=" + httpjson.Escape(provider.ClientSecret) +
			"&scope=" + httpjson.Escape(azureresource+"/.default")

		status, body, err := httpjson.Call(http.MethodPost, target,
			map[string]string{"content-type": "application/x-www-form-urlencoded"}, form)
		if nil != err {
			return "", err
		}

		got := httpjson.DigText(body, "access_token")
		if http.StatusOK != status || "" == got {
			return "", sekreto.Fail("sekreto: azure login failed: " + strconv.Itoa(status))
		}

		provider.renewat = httpjson.Expiry(httpjson.Dig(body, "expires_in"))
		return got, nil
	}

	imdsaddr := provider.ImdsAddr
	if "" == imdsaddr {
		imdsaddr = "http://169.254.169.254"
	}
	imds := strings.TrimSuffix(imdsaddr, "/") +
		"/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" +
		httpjson.Escape(azureresource)

	status, body, err := httpjson.Get(imds, map[string]string{"Metadata": "true"})
	if nil != err {
		return "", err
	}

	got := httpjson.DigText(body, "access_token")
	if http.StatusOK != status || "" == got {
		return "", sekreto.Fail("sekreto: azure: no token, no client credentials, and IMDS did not answer")
	}

	provider.renewat = httpjson.Expiry(httpjson.Dig(body, "expires_in"))
	return got, nil
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	// Serialize per-provider access: Lookup reads and refreshes the cached
	// login token, and a secrets client may resolve from several goroutines.
	provider.mu.Lock()
	defer provider.mu.Unlock()

	if "" == provider.Vault {
		return "", false, sekreto.Fail("sekreto: azure: no vault")
	}

	// Only an explicit scheme is a URL; a vault NAMED httpvault must
	// still become https://httpvault.vault.azure.net.
	vaulturl := provider.Vault
	if !strings.HasPrefix(vaulturl, "http://") && !strings.HasPrefix(vaulturl, "https://") {
		vaulturl = "https://" + vaulturl + ".vault.azure.net"
	}
	if err := sekreto.CheckAddr(vaulturl); nil != err {
		return "", false, err
	}

	if !provider.havetoken || httpjson.Due(provider.renewat) {
		token, err := provider.login()
		if nil != err {
			return "", false, err
		}
		provider.livetoken = token
		provider.havetoken = true
	}

	flat, err := sekreto.FlatName(name, "-")
	if nil != err {
		return "", false, err
	}

	apiversion := provider.ApiVersion
	if "" == apiversion {
		apiversion = "7.4"
	}
	target := strings.TrimSuffix(vaulturl, "/") + "/secrets/" + flat +
		"?api-version=" + apiversion

	status, body, err := httpjson.Get(target,
		map[string]string{"authorization": "Bearer " + provider.livetoken})
	if nil != err {
		return "", false, err
	}

	if http.StatusNotFound == status {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: azure error: " + strconv.Itoa(status) + ": " +
			httpjson.SafeURL(target))
	}

	value := httpjson.Dig(body, "value")
	if nil == value {
		return "", false, nil
	}

	return httpjson.ToString(value), true, nil
}

func (provider *Provider) Describe() string {
	return "azuresecrets:" + provider.Vault
}

// Plugin is the `azuresecrets` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("azuresecrets", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{
		Vault:        spec.Vault,
		Token:        spec.Token,
		Tenant:       spec.Tenant,
		ClientID:     spec.ClientID,
		ClientSecret: spec.ClientSecret,
		LoginAddr:    spec.LoginAddr,
		ImdsAddr:     spec.ImdsAddr,
		ApiVersion:   spec.ApiVersion,
	}, nil
})
