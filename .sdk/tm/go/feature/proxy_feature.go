package feature

import (
	neturl "net/url"
	"os"
	"regexp"
	"strings"

	"GOMODULE/core"
)

type ProxyFeature struct {
	BaseFeature
	client  *core.UnivecSDK
	options map[string]any
	noProxy []string
	url     string

	// Activity tracking (mirrors the ts client._proxy record); the url here
	// is the cleaned one, the routing target keeps its userinfo.
	Routed int
	Url    string
}

var proxyHostRe = regexp.MustCompile(`(?i)^[a-z]+://([^/:]+)`)

func NewProxyFeature() *ProxyFeature {
	return &ProxyFeature{
		BaseFeature: BaseFeature{
			Version: "0.0.1",
			Name:    "proxy",
			Active:  true,
		},
	}
}

func (f *ProxyFeature) Init(ctx *core.Context, options map[string]any) {
	f.client = ctx.Client
	f.options = options
	f.Active = foptBool(options, "active", false)

	if !f.Active {
		return
	}

	f.url = foptStr(f.options, "url", "")
	noProxy := foptStrList(f.options, "noProxy")

	if foptBool(f.options, "fromEnv", false) {
		if f.url == "" {
			f.url = firstEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy")
		}
		if noProxy == nil {
			if np := firstEnv("NO_PROXY", "no_proxy"); np != "" {
				noProxy = strings.Split(np, ",")
			}
		}
	}

	f.noProxy = []string{}
	for _, np := range noProxy {
		np = strings.TrimSpace(np)
		if np != "" {
			f.noProxy = append(f.noProxy, np)
		}
	}

	// A proxy URL may carry credentials as userinfo, from the option or the
	// environment, and neither is under a sensitive key name.
	f.Url = f.url
	if parsed, err := neturl.Parse(f.url); err == nil && parsed.User != nil {
		password, _ := parsed.User.Password()
		for _, part := range []string{parsed.User.Username(), password} {
			if part != "" && ctx.Utility.CleanAdd != nil {
				ctx.Utility.CleanAdd(ctx, part)
			}
		}
	}
	if ctx.Utility.Clean != nil {
		if cleaned, ok := ctx.Utility.Clean(ctx, f.url).(string); ok {
			f.Url = cleaned
		}
	}

	inner := ctx.Utility.Fetcher

	ctx.Utility.Fetcher = func(ctx2 *core.Context, url string, fetchdef map[string]any) (any, error) {
		fetchdef = f.route(url, fetchdef)
		return inner(ctx2, url, fetchdef)
	}
}

func (f *ProxyFeature) route(url string, fetchdef map[string]any) map[string]any {
	if f.url == "" || f.bypass(url) {
		return fetchdef
	}

	out := map[string]any{}
	for k, v := range fetchdef {
		out[k] = v
	}
	out["proxy"] = f.url

	f.Routed++
	return out
}

func (f *ProxyFeature) bypass(url string) bool {
	if len(f.noProxy) == 0 {
		return false
	}
	host := url
	if m := proxyHostRe.FindStringSubmatch(url); m != nil {
		host = m[1]
	}
	for _, np := range f.noProxy {
		if np == "*" {
			return true
		}
		if host == np || strings.HasSuffix(host, "."+strings.TrimPrefix(np, ".")) {
			return true
		}
	}
	return false
}

func firstEnv(names ...string) string {
	for _, name := range names {
		if v := os.Getenv(name); v != "" {
			return v
		}
	}
	return ""
}
