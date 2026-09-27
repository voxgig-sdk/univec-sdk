package feature

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"GOMODULE/core"
	plugin "GOMODULE/feature/secrets/plugin"
	sekreto "GOMODULE/feature/secrets/sekreto"
)

type SecretsFeature struct {
	BaseFeature
	client  *core.UnivecSDK
	options map[string]any

	liveopts map[string]any

	secretname string
	cache      bool
	sek        *sekreto.Sekreto

	exchange *secretsExchange
	refresh  string

	mu        sync.Mutex
	resolving *secretsCall
	buying    *secretsBuy
	initerr   error

	cred string
}

type secretsExchange struct {
	path     string
	method   string
	request  string
	response string
	statuses []int
	retries  int
}

type secretsCall struct {
	done chan struct{}
	err  error
}

type secretsBuy struct {
	done  chan struct{}
	token string
	err   error
}

func NewSecretsFeature() *SecretsFeature {
	return &SecretsFeature{
		BaseFeature: BaseFeature{
			Version: "0.1.0",
			Name:    "secrets",
			Active:  true,
		},
	}
}

// Sekreto is the LIVE instance, for callers who want arbitrary secrets or
// redaction (the go spelling of ts's public sekreto() accessor). Never a
// clone: sekreto holds provider state that has to stay live to be worth
// anything.
func (f *SecretsFeature) Sekreto() *sekreto.Sekreto {
	return f.sek
}

func (f *SecretsFeature) Init(ctx *core.Context, options map[string]any) {
	f.client = ctx.Client
	f.options = options
	f.liveopts = ctx.Options
	f.Active = foptBool(options, "active", false)

	if !f.Active {
		return
	}

	f.secretname = foptStr(options, "name", "apikey")
	if "" == f.secretname {
		f.secretname = "apikey"
	}
	f.cache = foptBool(options, "cache", true)

	xopts := foptMap(options, "exchange")
	if foptBool(xopts, "active", false) {
		statuses := []int{}
		for _, s := range foptList(xopts, "statuses") {
			statuses = append(statuses, core.ToInt(s))
		}
		if 0 == len(statuses) {
			statuses = []int{401}
		}
		f.exchange = &secretsExchange{
			path:     foptStr(xopts, "path", "auth/token"),
			method:   foptStr(xopts, "method", "POST"),
			request:  foptStr(xopts, "request", "refresh_token"),
			response: foptStr(xopts, "response", "access_token"),
			statuses: statuses,
			retries:  foptInt(xopts, "retries", 1),
		}
	}

	explicit := ""
	if nil == f.exchange {
		explicit, _ = f.liveopts["apikey"].(string)
	} else {
		explicit = foptStr(xopts, "refresh", "")
	}

	specs := []*sekreto.ProviderSpec{}

	if "" != explicit {
		key, err := sekreto.EnvKey(f.secretname, "")
		if nil == err {
			specs = append(specs, &sekreto.ProviderSpec{
				Kind:   "memory",
				Name:   "options",
				Values: map[string]string{key: explicit},
			})
		}
	}

	for _, p := range foptList(options, "providers") {
		switch v := p.(type) {
		case *sekreto.ProviderSpec:
			specs = append(specs, v)
		case sekreto.Provider:
			specs = append(specs, &sekreto.ProviderSpec{Provider: v})
		case map[string]any:
			spec, err := sekreto.SpecOf(v)
			if nil != err {
				f.initerr = err
				continue
			}
			specs = append(specs, spec)
		default:
			f.initerr = sekreto.Fail(
				"sekreto: not a provider or a provider spec: " + fmt.Sprint(v))
		}
	}

	// The plugin DEFINITIONS the model selected for this feature, emitted
	// by Config generically from the catalogue's active `plugin.def`
	// entries. Upstream sekreto's contract since the registry was retired:
	// a kind not passed in Plugins is unknown to this Sekreto, so the
	// model's choice of plugin groups IS the SDK's provider vocabulary.
	plugs := []plugin.Definition{}
	for _, d := range core.FeaturePlugins(f.Name) {
		if def, is := d.(plugin.Definition); is {
			plugs = append(plugs, def)
		}
	}

	sek, err := sekreto.New(&sekreto.Options{
		Providers: specs,
		Plugins:   plugs,
		NoCache:   !f.cache,
	})
	if nil != err {
		// Init cannot fail the construction the way ts's throwing init
		// does; the transport gate below refuses to send instead, which
		// keeps a misconfigured chain fail-closed rather than silently
		// unauthenticated.
		f.initerr = err
		return
	}
	f.sek = sek

	self := f
	inner := ctx.Utility.Fetcher
	ctx.Utility.Fetcher = func(ctx2 *core.Context, url string, fetchdef map[string]any) (any, error) {
		return self.transport(ctx2, url, fetchdef, inner)
	}
}

func (f *SecretsFeature) resolve() error {
	if nil != f.initerr {
		return f.initerr
	}

	f.mu.Lock()
	if call := f.resolving; nil != call {
		f.mu.Unlock()
		<-call.done
		return call.err
	}
	call := &secretsCall{done: make(chan struct{})}
	f.resolving = call
	f.mu.Unlock()

	hit, err := f.resolveonce()

	f.mu.Lock()
	call.err = err
	if nil != err || !f.cache || !hit {
		f.resolving = nil
	}
	f.mu.Unlock()
	close(call.done)

	return err
}

// resolveonce resolves once, reporting whether a credential came out of it.
// That bool is the whole of what resolve() needs to tell a cacheable HIT
// from a miss it must not retain.
func (f *SecretsFeature) resolveonce() (bool, error) {
	if nil == f.sek {
		return false, nil
	}

	found, has, err := f.sek.Try(f.secretname)
	if nil != err {
		return false, err
	}

	if nil == f.exchange {
		f.mu.Lock()
		if has {
			f.cred = found
		} else {
			f.cred = ""
		}
		f.mu.Unlock()
		return has, nil
	}

	// Exchanging: what the chain resolved is the REFRESH token, kept for
	// every later purchase. A miss is not fatal here - an explicit
	// `apikey` may already hold a usable access token, and the API is
	// what gets to say whether it does.
	f.refresh = ""
	if has {
		f.refresh = found
	}

	f.mu.Lock()
	apikey := f.cred
	f.mu.Unlock()
	if "" == apikey {
		apikey, _ = f.liveopts["apikey"].(string)
		f.mu.Lock()
		f.cred = apikey
		f.mu.Unlock()
	}
	if "" != apikey {
		return true, nil
	}

	if nil == f.liveopts["auth"] {
		return false, nil
	}

	_, err = f.buy()
	return nil == err, err
}

func (f *SecretsFeature) transport(ctx *core.Context, url string,
	fetchdef map[string]any, inner core.FetcherFunc) (any, error) {

	if nil != f.initerr {
		return nil, f.initerr
	}
	if err := f.resolve(); nil != err {
		return nil, err
	}

	// Inject the resolved credential into THIS request's header. The
	// header was built by prepareAuth from the options apikey; the
	// chain-resolved value lives in feature state instead (see `cred`),
	// so the wrapper writes it here - same construction, same
	// suppression rules - and the shared options map stays untouched.
	if token := f.getcred(); "" != token {
		f.reauth(fetchdef, token)
	}

	if nil == f.exchange {
		return inner(ctx, url, fetchdef)
	}

	return f.withrefresh(ctx, url, fetchdef, inner)
}

func (f *SecretsFeature) withrefresh(ctx *core.Context, url string,
	fetchdef map[string]any, inner core.FetcherFunc) (any, error) {

	if nil == f.liveopts["auth"] {
		return inner(ctx, url, fetchdef)
	}

	max := f.exchange.retries
	attempt := 0

	for {
		used := f.getcred()

		res, err := inner(ctx, url, fetchdef)

		if nil != err || attempt >= max || !f.spent(res) {
			return res, err
		}

		current := f.getcred()
		token := ""

		if "" != current && current != used {
			token = current
		} else {
			bought, berr := f.buy()
			if nil != berr {
				// The purchase failed: answer with the API's own refusal
				// rather than this one. The caller asked for data, and
				// the refusal is the more useful of the two - the
				// exchange error is a symptom.
				return res, nil
			}
			// buy() published the token to the live options under the
			// feature mutex - the PURCHASING goroutine is the only
			// writer, so a burst of expired requests cannot race the
			// map. Waiters use the returned value directly.
			token = bought
		}

		f.reauth(fetchdef, token)

		attempt++
	}
}

func (f *SecretsFeature) spent(res any) bool {
	status, is := fresStatus(res)
	if !is {
		return false
	}
	for _, s := range f.exchange.statuses {
		if s == status {
			return true
		}
	}
	return false
}

func (f *SecretsFeature) getcred() string {
	f.mu.Lock()
	v := f.cred
	f.mu.Unlock()
	return v
}

// Credential exposes the resolved credential (empty when none) - the
// state the transport injects; tests and callers read it here rather
// than from the options map, which this feature never mutates.
func (f *SecretsFeature) Credential() string {
	return f.getcred()
}

func (f *SecretsFeature) reauth(fetchdef map[string]any, token string) {
	headers, _ := fetchdef["headers"].(map[string]any)
	if nil == headers {
		return
	}

	rawauth := f.liveopts["auth"]
	auth, _ := rawauth.(map[string]any)
	if nil == rawauth || nil == auth {
		delete(headers, "authorization")
		return
	}

	prefix, _ := auth["prefix"].(string)
	if "" == prefix {
		headers["authorization"] = token
	} else {
		headers["authorization"] = prefix + " " + token
	}
}

// buy an access token with the refresh token. Concurrent callers share the
// ONE in-flight purchase; the slot is cleared once settled, so the next
// expiry buys a fresh token rather than replaying this result.
func (f *SecretsFeature) buy() (string, error) {
	if "live" != f.client.Mode {
		token := "test-" + f.exchange.response
		f.mu.Lock()
		f.cred = token
		f.mu.Unlock()
		return token, nil
	}

	f.mu.Lock()
	if buying := f.buying; nil != buying {
		f.mu.Unlock()
		<-buying.done
		return buying.token, buying.err
	}
	buying := &secretsBuy{done: make(chan struct{})}
	f.buying = buying
	f.mu.Unlock()

	token, err := f.buyonce()

	f.mu.Lock()
	buying.token = token
	buying.err = err
	f.buying = nil
	if nil == err {
		f.cred = token
	}
	f.mu.Unlock()
	close(buying.done)

	return token, err
}

func (f *SecretsFeature) buyonce() (string, error) {
	x := f.exchange

	if "" == f.refresh {
		return "", sekreto.Fail(
			"secrets: no refresh token: the provider chain has no '" +
				f.secretname + "', and feature.secrets.exchange.refresh is unset")
	}

	options := f.client.OptionsMap()

	base, _ := options["base"].(string)
	base = strings.TrimRight(base, "/")
	url := base + "/" + strings.TrimLeft(x.path, "/")

	system, _ := options["system"].(map[string]any)
	fetch, _ := system["fetch"].(func(string, map[string]any) (map[string]any, error))

	if nil == fetch {
		fetch = rawExchangeFetch
	}

	// The body is MARSHALLED, never concatenated: a refresh token (or a
	// configured request-field name) carrying a quote, backslash or
	// newline must arrive as that literal value, not as malformed JSON.
	bodybytes, err := json.Marshal(map[string]string{x.request: f.refresh})
	if nil != err {
		return "", err
	}

	res, err := fetch(url, map[string]any{
		"method":  x.method,
		"headers": map[string]any{"content-type": "application/json"},
		"body":    string(bodybytes),
	})
	if nil != err {
		return "", err
	}

	status := core.ToInt(res["status"])
	if 200 > status || 300 <= status {
		return "", sekreto.Fail(
			"secrets: token exchange failed: " + strconv.Itoa(status) + " from " + url)
	}

	var body any
	if jf, is := res["json"].(func() any); is {
		body = jf()
	} else {
		body = res["body"]
	}

	token := ""
	if bodymap, is := body.(map[string]any); is {
		token, _ = bodymap[x.response].(string)
	}

	if "" == token {
		return "", sekreto.Fail(
			"secrets: token exchange returned no '" + x.response + "' field from " + url)
	}

	return token, nil
}

// rawExchangeFetch is the token-exchange transport of last resort: plain
// net/http, same result shape the system.fetch seam promises ("status" +
// "json"). It exists so an exchange works with ordinary SDK options -
// requiring a custom transport for the COMMON case would reject every
// live token purchase before a request was made.
func rawExchangeFetch(fullurl string, fetchdef map[string]any) (map[string]any, error) {
	method, _ := fetchdef["method"].(string)
	if "" == method {
		method = "POST"
	}

	var body io.Reader
	if raw, is := fetchdef["body"].(string); is && "" != raw {
		body = strings.NewReader(raw)
	}

	req, err := http.NewRequest(method, fullurl, body)
	if nil != err {
		return nil, err
	}
	if headers, is := fetchdef["headers"].(map[string]any); is {
		for k, v := range headers {
			if vs, is := v.(string); is {
				req.Header.Set(k, vs)
			}
		}
	}

	client := &http.Client{Timeout: 30 * time.Second}
	res, err := client.Do(req)
	if nil != err {
		return nil, err
	}
	defer res.Body.Close()

	raw, err := io.ReadAll(res.Body)
	if nil != err {
		return nil, err
	}

	return map[string]any{
		"status": res.StatusCode,
		"json": func() any {
			var out any
			if nil != json.Unmarshal(raw, &out) {
				return nil
			}
			return out
		},
	}, nil
}
