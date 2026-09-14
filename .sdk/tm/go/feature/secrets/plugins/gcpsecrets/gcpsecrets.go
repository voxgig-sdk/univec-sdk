// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/gcpsecrets/gcpsecrets.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The gcpsecrets plugin: GCP Secret Manager. Needs HTTPS. A port of
// typescript/plugins/gcpsecrets.ts.
package gcpsecrets

import (
	"encoding/base64"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads GCP Secret Manager.
//
// api.token reads secret api_token (dots flattened to `_`; Secret Manager
// ids have no hierarchy and reject dots), latest version. The token comes
// from config, then GOOGLE_OAUTH_ACCESS_TOKEN, then the GCE/GKE metadata
// server - so on Google's own platform no credential configuration is
// needed at all.
//
// The metadata call itself is plain http to a link-local host by platform
// design; no credential rides on it, so checkaddr guards the Secret
// Manager address instead.
type Provider struct {
	Project      string
	Token        string
	Addr         string
	MetadataAddr string
	// A configured token is kept forever; a metadata-server token carries
	// expires_in and is renewed shortly before it runs out.
	livetoken string
	havetoken bool
	renewat   time.Time
	mu        sync.Mutex
}

func (provider *Provider) metadataaddr() string {
	if "" != provider.MetadataAddr {
		return provider.MetadataAddr
	}
	if host := os.Getenv("GCE_METADATA_HOST"); "" != host {
		return "http://" + host
	}
	return "http://metadata.google.internal"
}

func (provider *Provider) login() (string, error) {
	configured := provider.Token
	if "" == configured {
		configured = os.Getenv("GOOGLE_OAUTH_ACCESS_TOKEN")
	}
	if "" != configured {
		return configured, nil
	}

	target := strings.TrimSuffix(provider.metadataaddr(), "/") +
		"/computeMetadata/v1/instance/service-accounts/default/token"

	status, body, err := httpjson.Get(target, map[string]string{"Metadata-Flavor": "Google"})
	if nil != err {
		return "", err
	}

	got := httpjson.DigText(body, "access_token")
	if http.StatusOK != status || "" == got {
		return "", sekreto.Fail("sekreto: gcp: no token and metadata server did not answer")
	}

	provider.renewat = httpjson.Expiry(httpjson.Dig(body, "expires_in"))

	return got, nil
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	// Serialize per-provider access: Lookup reads and refreshes the cached
	// login token, and a secrets client may resolve from several goroutines.
	provider.mu.Lock()
	defer provider.mu.Unlock()

	if "" == provider.Project {
		return "", false, sekreto.Fail("sekreto: gcp: no project")
	}

	addr := provider.Addr
	if "" == addr {
		addr = "https://secretmanager.googleapis.com"
	}
	if err := sekreto.CheckAddr(addr); nil != err {
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

	flat, err := sekreto.FlatName(name, "_")
	if nil != err {
		return "", false, err
	}

	target := strings.TrimSuffix(addr, "/") + "/v1/projects/" + provider.Project +
		"/secrets/" + flat + "/versions/latest:access"

	status, body, err := httpjson.Get(target,
		map[string]string{"authorization": "Bearer " + provider.livetoken})
	if nil != err {
		return "", false, err
	}

	if http.StatusNotFound == status {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: gcp error: " + strconv.Itoa(status) + ": " + target)
	}

	data, is := httpjson.Dig(body, "payload", "data").(string)
	if !is {
		return "", false, nil
	}

	// See the aws provider: an undecodable payload is an error, not a miss.
	decoded, err := base64.StdEncoding.DecodeString(data)
	if nil != err {
		return "", false, sekreto.Fail("sekreto: gcp: undecodable secret")
	}
	return string(decoded), true, nil
}

func (provider *Provider) Describe() string {
	return "gcpsecrets:" + provider.Project
}

// Plugin is the `gcpsecrets` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("gcpsecrets", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{
		Project:      spec.Project,
		Token:        spec.Token,
		Addr:         spec.Addr,
		MetadataAddr: spec.MetadataAddr,
	}, nil
})
