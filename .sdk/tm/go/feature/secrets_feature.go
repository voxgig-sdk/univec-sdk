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

// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The go port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, go idiom.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
//
// Resolution is effectively ASYNC (providers do IO), and the auth header is
// built by the synchronous prepareAuth inside makeSpec. The bridge is the
// feature hook pipeline: every entity op runs featureHook("PreSpec") before
// makeSpec, so the PreSpec hook below resolves the secret once and writes
// it into the LIVE options map where prepareAuth already looks (ctx.Options
// on the root context IS the options map the client clones for OptionsMap).
// Concurrent operations share the single in-flight resolution.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
// vault never degrades into an unauthenticated request. go's feature hooks
// are synchronous and cannot fail an operation from PreSpec the way ts's
// awaited hook rejection can - so, unlike ts, the transport is wrapped
// WHENEVER the feature is active, and the wrapper refuses to send while
// the last resolution stands failed. Fail-closed at the one seam every
// request must pass.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when
// a response status in `exchange.statuses` (401) says it is spent the
// wrapper buys another and retries the same request once. Concurrent
// purchases share the one in-flight exchange; test mode buys nothing and
// answers with a deterministic fake token.
type SecretsFeature struct {
	BaseFeature
	client  *core.UnivecSDK
	options map[string]any

	// The LIVE options map (root ctx options), where the resolved value
	// lands so the sync prepareAuth sees it.
	liveopts map[string]any

	secretname string
	cache      bool
	sek        *sekreto.Sekreto

	// Exchange state: nil config when off; the refresh credential the
	// chain resolved; the single in-flight purchase.
	exchange *secretsExchange
	refresh  string

	mu        sync.Mutex
	resolving *secretsCall
	buying    *secretsBuy
	initerr   error

	// The RESOLVED credential, held in feature state and injected into
	// each request at the transport seam - NEVER written into the shared
	// live options map. This is go's structural deviation from the ts
	// reference (which writes options.apikey): the go request path reads
	// ctx.Options raw on every operation goroutine, so a feature that
	// mutated that map would race every concurrent operation. With the
	// feature as sole holder, the options map is frozen after
	// construction and every raw read is safe; the header the wire sees
	// is identical, because the transport wrapper rewrites it from this
	// value the same way prepareAuth builds it.
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

// One shared in-flight resolution: late arrivals wait on done and read err.
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

// Init is sync by feature contract: build the chain, never look anything
// up here.
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

	// Exchange config, normalised once. Nil when off, so every later
	// decision is a nil check.
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

	// The explicit credential, when set, is the first store in the chain.
	//
	// WHICH option that is depends on the exchange. Without one, the
	// secret being resolved IS the credential the transport sends, so
	// `apikey` is it. With one, the secret is a REFRESH token and `apikey`
	// means the opposite thing - an access token the caller already holds
	// - so the explicit seat belongs to `exchange.refresh`, and apikey is
	// left alone to serve as the starting access token (see resolveonce).
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
			// A provider already built joins the chain as it is.
			specs = append(specs, &sekreto.ProviderSpec{Provider: v})
		case map[string]any:
			spec, err := sekreto.SpecOf(v)
			if nil != err {
				f.initerr = err
				continue
			}
			specs = append(specs, spec)
		default:
			// ANYTHING ELSE is refused, fail-closed - a bare kind name
			// ("hashicorp"), a nil, a number. DELIBERATE DIVERGENCE from
			// ts/kotlin: those push every entry through to Sekreto's
			// constructor, whose dynamic providers list refuses it with this
			// message. Go's Options.Providers is a typed slice, so there is
			// nothing to push a string through; the feature raises the
			// library's own error here instead, via sekreto.Fail with the
			// constructor's own wording, and the transport gate below refuses
			// to send. A switch without this arm silently DROPPED the entry,
			// which SHORTENED the chain instead of failing it - a
			// misconfigured providers list then sent ordinary unauthenticated
			// requests, the exact fail-open the gate exists to prevent.
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

	// Wrap the transport: the fail-closed gate needs the seam whenever the
	// feature is active, and the exchange (when on) additionally needs to
	// SEE responses - expiry is only ever discovered from one, and this is
	// the one place a response can be seen and the request tried again.
	self := f
	inner := ctx.Utility.Fetcher
	ctx.Utility.Fetcher = func(ctx2 *core.Context, url string, fetchdef map[string]any) (any, error) {
		return self.transport(ctx2, url, fetchdef, inner)
	}
}

// resolve runs one resolution, shared by every concurrent caller. A
// settled HIT is kept only when caching is on (`cache: false` means every
// resolve asks the chain again); a FAILURE is always cleared, so a
// transient vault outage never poisons the client permanently - the next
// operation asks the chain again.
//
// A MISS is cleared too, however caching is set. That rule is sekreto's,
// not this feature's: `A miss is never cached: the next read asks again`,
// in sekreto's own source. Retaining a settled miss here would override
// that from the layer above, and a secret provisioned after startup - a
// mounted file, a policy granted a minute late - would never be picked up
// for the life of the client. `cache` is about caching a HIT; it was never
// a promise to keep saying no.
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
		// A provider ERROR fails the op (via the transport gate); only a
		// MISS falls through.
		return false, err
	}

	if nil == f.exchange {
		f.mu.Lock()
		if has {
			f.cred = found
		} else {
			// An UNCACHED miss after an earlier hit is a revocation: the
			// chain now says no provider has the secret, so the resolved
			// value must not keep going out on the wire. (An explicit
			// apikey OPTION is never lost here - it seats FIRST in the
			// chain as a memory provider, so the chain HITS while one is
			// set and the miss branch is unreachable.)
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
		// A starting access token supplied as the OPTION: read from the
		// frozen options map (no feature ever writes it).
		apikey, _ = f.liveopts["apikey"].(string)
		f.mu.Lock()
		f.cred = apikey
		f.mu.Unlock()
	}
	if "" != apikey {
		// A starting access token was supplied. Spend it: if it is stale
		// the API answers with an expiry status and the transport wrapper
		// buys another, which is the same path expiry takes anyway.
		return true, nil
	}

	// `auth: nil` is the documented way to send NO credential, and a
	// purchase is a credential-bearing call: the refresh token goes to the
	// token endpoint in the request body. withrefresh honours suppression
	// for the RETRY, but it runs after this - by then the refresh token has
	// already left the process, and no later check can call it back. The
	// suppression has to be honoured here, before the first purchase, or it
	// only ever half-held.
	if nil == f.liveopts["auth"] {
		return false, nil
	}

	_, err = f.buy()
	return nil == err, err
}

// transport wraps whatever transport was current at Init.
func (f *SecretsFeature) transport(ctx *core.Context, url string,
	fetchdef map[string]any, inner core.FetcherFunc) (any, error) {

	// Fail-closed, at the ONE seam every wire path crosses. Entity ops,
	// Direct, Graphql and the exchange retries all come through this
	// wrapper, so resolving HERE is what gives the raw paths - which run
	// no feature hooks at all - the same credential the entity pipeline
	// gets (ts resolves in its awaited PreSpec instead; go's header is
	// rewritten below AFTER Prepare built it, so the transport is exactly
	// early enough). resolve() is shared and cached: concurrent callers
	// join the in-flight attempt, a cached success is free, and with
	// `cache: false` the chain is asked once per REQUEST, which is that
	// option's meaning. A provider ERROR refuses the request with the
	// provider's error - never an unauthenticated send.
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

// withrefresh buys a token and tries the request again when the API says
// the current one is spent.
//
// The retry rewrites the authorization header IN PLACE on the fetchdef,
// because the header was built by the synchronous prepareAuth before this
// request left, and it carries the token that just failed. Rebuilt the way
// prepareAuth builds it, from the same options auth.prefix, so the two
// cannot drift.
func (f *SecretsFeature) withrefresh(ctx *core.Context, url string,
	fetchdef map[string]any, inner core.FetcherFunc) (any, error) {

	// `auth: nil` is the documented way to send NO credential, and
	// prepareAuth honours it by removing the header. A refusal of a
	// deliberately unauthenticated request is not an expired token and
	// cannot be fixed by buying one - retrying would transmit exactly the
	// credential the caller suppressed.
	if nil == f.liveopts["auth"] {
		return inner(ctx, url, fetchdef)
	}

	max := f.exchange.retries
	attempt := 0

	for {
		// The credential THIS attempt goes out with, captured before it
		// leaves: it is what tells a stale refusal apart from a fresh one.
		used := f.getcred()

		res, err := inner(ctx, url, fetchdef)

		if nil != err || attempt >= max || !f.spent(res) {
			return res, err
		}

		// Another request may have bought a token while this one was in
		// flight. Concurrent expiries share the in-flight purchase, but
		// STAGGERED ones do not - so spend what is current before buying:
		// a second exchange for a token that is already fresh is wasted,
		// and on a provider that invalidates the previous credential on
		// issuance it breaks the first request's own retry.
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

// getcred reads the resolved credential under the feature mutex.
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

	// Suppressed auth means NO header, the same answer prepareAuth gives.
	// Reached defensively - withrefresh does not retry at all when auth is
	// nil - but this is the function that writes the credential, so it is
	// where the rule has to hold.
	// The options map is FROZEN after construction (this feature never
	// writes it), so the raw read is safe on any goroutine.
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
	// TEST MODE BUYS NOTHING. The test feature replaces the transport so
	// no request leaves the process; an exchange here would be the one
	// HTTP call it could not stop, and it would need a live token endpoint
	// for a suite whose whole point is not needing one. A deterministic,
	// obviously-fake token instead - the same answer makeOptions gives a
	// required server variable, for the same reason.
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
		// Publish HERE, before the waiters wake: one writer, under the
		// mutex - waiters consume the returned value.
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

	// The token endpoint is RELATIVE to the base, which already carries
	// whatever account or tenant segment the server URL declares.
	base, _ := options["base"].(string)
	base = strings.TrimRight(base, "/")
	url := base + "/" + strings.TrimLeft(x.path, "/")

	system, _ := options["system"].(map[string]any)
	fetch, _ := system["fetch"].(func(string, map[string]any) (map[string]any, error))

	if nil == fetch {
		// No custom transport supplied - the ordinary case. makeOptions
		// leaves system.fetch unset, so the exchange gets its own raw
		// HTTP path (mirroring the ts reference, whose system.fetch is
		// initialized from the platform fetcher). Local and minimal on
		// purpose: see the NOT-the-SDK-transport note below.
		fetch = rawExchangeFetch
	}

	// The body is MARSHALLED, never concatenated: a refresh token (or a
	// configured request-field name) carrying a quote, backslash or
	// newline must arrive as that literal value, not as malformed JSON.
	bodybytes, err := json.Marshal(map[string]string{x.request: f.refresh})
	if nil != err {
		return "", err
	}

	// Deliberately NOT the SDK transport. The transport is what this
	// feature wraps, and sending the token request back through it would
	// recurse on the first expiry - and would route the exchange through
	// the test mock, which knows nothing about it.
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
