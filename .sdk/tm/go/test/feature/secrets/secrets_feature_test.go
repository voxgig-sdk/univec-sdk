// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the go port of tm/ts/test/feature/secrets/Secrets.test.ts.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic.
// With the feature inactive nothing changes at all. With it active and the
// option unset, the chain (env, a custom provider, a vault) supplies the
// credential instead.
//
// This file lives in the test `feature/` container on purpose: `target
// add` trims it, along with the feature source and the vendored library,
// for a project whose model does not select `secrets`.
//
// The feature is CONSTRUCTED DIRECTLY and handed in through the
// `extend` option, so these tests hold in any generated tree - whether or
// not the project's model activated the feature (activation only changes
// whether config.go registers a constructor for it). The credential is
// asserted ON THE WIRE: a live-mode client with a recording system.fetch,
// driven through a real entity operation, which is what exercises the
// PreSpec resolution seam. (See the migration guide: an options-level
// assertion passes for a port that never consults the value.)

package secretstest

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode"

	sdk "GOMODULE"
	feat "GOMODULE/feature"
)

const envprefix = "PROJECTENV_TEST_SECRETS_"

// ---------------------------------------------------------------------
// The recording transport: system.fetch for a LIVE client, scripting one
// status per API call (the last repeating) and a token endpoint for the
// exchange tests.

type wirecall struct {
	url  string
	auth string
	has  bool
	body string
}

type wire struct {
	mu        sync.Mutex
	calls     []wirecall
	apistatus []int
	tokens    []string
	tokenpath string
	respfield string
	issued    int
	apicalls  int
}

func makewire() *wire {
	return &wire{
		apistatus: []int{200},
		tokens:    []string{"ACCESS01", "ACCESS02", "ACCESS03"},
		tokenpath: "auth/token",
		respfield: "access_token",
	}
}

func (w *wire) fetch(url string, fetchdef map[string]any) (map[string]any, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	auth := ""
	has := false
	if headers, is := fetchdef["headers"].(map[string]any); is {
		if v, found := headers["authorization"]; found {
			auth, _ = v.(string)
			has = true
		}
	}
	body, _ := fetchdef["body"].(string)
	w.calls = append(w.calls, wirecall{url: url, auth: auth, has: has, body: body})

	if strings.HasSuffix(url, "/"+w.tokenpath) {
		token := w.tokens[min(w.issued, len(w.tokens)-1)]
		w.issued++
		payload := map[string]any{w.respfield: token}
		return map[string]any{
			"status": 200, "statusText": "OK",
			"headers": map[string]any{},
			"json":    (func() any)(func() any { return payload }),
		}, nil
	}

	status := w.apistatus[min(w.apicalls, len(w.apistatus)-1)]
	w.apicalls++
	payload := map[string]any{"ok": status < 400}
	return map[string]any{
		"status": status, "statusText": "X",
		"headers": map[string]any{},
		"json":    (func() any)(func() any { return payload }),
	}, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// api returns the recorded calls that did NOT go to the token endpoint.
func (w *wire) api() []wirecall {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := []wirecall{}
	for _, c := range w.calls {
		if !strings.HasSuffix(c.url, "/"+w.tokenpath) {
			out = append(out, c)
		}
	}
	return out
}

func (w *wire) token() []wirecall {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := []wirecall{}
	for _, c := range w.calls {
		if strings.HasSuffix(c.url, "/"+w.tokenpath) {
			out = append(out, c)
		}
	}
	return out
}

// ---------------------------------------------------------------------
// Support.

// The Authorization header carries the SPEC's credential prefix, which a
// TEMPLATE cannot know - so assert on the CREDENTIAL and let the prefix be
// whatever this SDK's API declares.
func credentialIs(t *testing.T, header string, token string) {
	t.Helper()
	if header != token && !strings.HasSuffix(header, " "+token) {
		t.Fatalf("expected the authorization header to carry %s, got: %q", token, header)
	}
}

// secretsClient builds a LIVE client carrying the secrets feature via the
// `extend` seam, wired to the recording transport.
func secretsClient(w *wire, sdkopts map[string]any) *sdk.UnivecSDK {
	opts := map[string]any{
		"base":   "http://secrets.test/api",
		"system": map[string]any{"fetch": w.fetch},
	}
	for k, v := range sdkopts {
		opts[k] = v
	}
	return withSecrets(func(extend bool) *sdk.UnivecSDK {
		if extend {
			opts["extend"] = []any{feat.NewSecretsFeature()}
		}
		return sdk.NewUnivecSDK(opts)
	})
}

// withSecrets constructs the client and ADOPTS the feature via `extend`
// ONLY when the generated config did not already install it - when this
// SDK was generated with `secrets` model-active, the ordinary factory
// path builds the instance, and adding a second via extend would DOUBLE
// the feature: two transport wraps, two resolutions, and a token
// purchase the assertions cannot account for. (The py harness guards the
// same way via _has_feature.)
func withSecrets(build func(extend bool) *sdk.UnivecSDK) *sdk.UnivecSDK {
	client := build(false)
	if nil == secretsFeatureOf(client) {
		client = build(true)
	}
	return client
}

func secretsOpts(extra map[string]any) map[string]any {
	fopts := map[string]any{
		"active": true,
		"providers": []any{
			map[string]any{"kind": "env", "prefix": envprefix},
		},
	}
	for k, v := range extra {
		fopts[k] = v
	}
	return map[string]any{"secrets": fopts}
}

// secretsFeatureOf digs the live feature back out of the client, for
// assertions against its Sekreto instance.
func secretsFeatureOf(client *sdk.UnivecSDK) *feat.SecretsFeature {
	for _, f := range client.Features {
		if sf, is := f.(*feat.SecretsFeature); is {
			return sf
		}
	}
	return nil
}

// driveEntityOpUntil performs real entity operations - which is what runs
// the PreSpec hook - until `stop` reports the observable state a test is
// waiting for. Each op's own outcome is irrelevant (no seeded data, a
// scripted response); an op the API does not define fails BEFORE the
// PreSpec hook, which is why several may need driving. Entity names come
// from the SDK's own config, because this file is a TEMPLATE and no
// project's entity names are known here.
func driveEntityOpUntil(t *testing.T, client *sdk.UnivecSDK, what string, stop func() bool) {
	t.Helper()

	entities, _ := client.OptionsMap()["entity"].(map[string]any)
	clientval := reflect.ValueOf(client)

	for name := range entities {
		runes := []rune(name)
		runes[0] = unicode.ToUpper(runes[0])
		accessor := clientval.MethodByName(string(runes))
		if !accessor.IsValid() || 1 != accessor.Type().NumIn() {
			continue
		}

		ent := accessor.Call([]reflect.Value{
			reflect.Zero(accessor.Type().In(0)),
		})[0]

		for _, opname := range []string{"List", "Load"} {
			op := ent.MethodByName(opname)
			if !op.IsValid() {
				continue
			}
			in := make([]reflect.Value, op.Type().NumIn())
			for i := range in {
				in[i] = reflect.Zero(op.Type().In(i))
			}
			op.Call(in)

			if stop() {
				return
			}
		}
	}

	t.Fatalf("no entity operation %s - nothing to assert on", what)
}

// driveEntityOp drives ops until one request reached the recorder.
func driveEntityOp(t *testing.T, client *sdk.UnivecSDK, w *wire) {
	t.Helper()
	before := len(w.api())
	driveEntityOpUntil(t, client, "reached the transport", func() bool {
		return before < len(w.api())
	})
}

// ---------------------------------------------------------------------
// The feature-inactive baseline: bit-identical behaviour.

func TestSecretsInactive(t *testing.T) {

	t.Run("apikey option behaves exactly as before", func(t *testing.T) {
		client := sdk.TestSDK(nil, map[string]any{"apikey": "OPTKEY01"})
		fetchdef, err := client.Prepare(map[string]any{"path": "/"})
		if err != nil {
			t.Fatalf("prepare failed: %v", err)
		}
		headers, _ := fetchdef["headers"].(map[string]any)
		auth, _ := headers["authorization"].(string)
		credentialIs(t, auth, "OPTKEY01")

		if nil != secretsFeatureOf(client) {
			t.Fatal("no model activation, no extend: the feature must not be installed")
		}
	})

	t.Run("no apikey means no authorization header", func(t *testing.T) {
		client := sdk.TestSDK(nil, nil)
		fetchdef, err := client.Prepare(map[string]any{"path": "/"})
		if err != nil {
			t.Fatalf("prepare failed: %v", err)
		}
		headers, _ := fetchdef["headers"].(map[string]any)
		if _, has := headers["authorization"]; has {
			t.Fatalf("unexpected authorization header: %v", headers["authorization"])
		}
	})
}

// ---------------------------------------------------------------------
// Active: the provider chain, driven through real entity operations.

func TestSecretsChain(t *testing.T) {

	t.Run("apikey option still wins over the chain", func(t *testing.T) {
		os.Setenv(envprefix+"APIKEY", "ENVKEY01")
		defer os.Unsetenv(envprefix + "APIKEY")

		w := makewire()
		client := secretsClient(w, map[string]any{
			"apikey":  "OPTKEY01",
			"feature": secretsOpts(nil),
		})

		driveEntityOp(t, client, w)
		call := w.api()[0]
		credentialIs(t, call.auth, "OPTKEY01")

		// The explicit option is a real store, not a special case: a
		// directed read names it like any other.
		sf := secretsFeatureOf(client)
		if nil == sf {
			t.Fatal("the extend seam did not install the feature")
		}
		found, err := sf.Sekreto().GetFrom("options", "apikey")
		if err != nil || "OPTKEY01" != found {
			t.Fatalf("directed read of the options store: %q, %v", found, err)
		}
	})

	t.Run("an omitted apikey defers to the chain at the transport seam", func(t *testing.T) {
		os.Setenv(envprefix+"APIKEY", "ENVKEY02")
		defer os.Unsetenv(envprefix + "APIKEY")

		w := makewire()
		client := secretsClient(w, map[string]any{"feature": secretsOpts(nil)})

		// Before any op, nothing has been resolved.
		if v, _ := client.OptionsMap()["apikey"].(string); "" != v {
			t.Fatalf("apikey resolved before any operation: %q", v)
		}

		driveEntityOp(t, client, w)

		// Resolution happens AT THE TRANSPORT - the one seam every wire
		// path crosses - so the credential is on the wire, not merely
		// resolved. go holds it in FEATURE STATE and injects there; the
		// options map is never mutated (it stays raced-read-safe for
		// every concurrent operation), so the state assertion reads the
		// feature.
		credentialIs(t, w.api()[0].auth, "ENVKEY02")
		if v := secretsFeatureOf(client).Credential(); "ENVKEY02" != v {
			t.Fatalf("the entity op did not resolve the secret through PreSpec: %q", v)
		}
		if v, _ := client.OptionsMap()["apikey"].(string); "" != v {
			t.Fatalf("the options map must stay unwritten (frozen after construction), got apikey=%q", v)
		}
	})

	t.Run("custom provider objects are accepted verbatim", func(t *testing.T) {
		asked := []string{}
		w := makewire()
		client := secretsClient(w, map[string]any{
			"feature": map[string]any{"secrets": map[string]any{
				"active": true,
				"providers": []any{
					&customProvider{
						lookup: func(name string) (string, bool, error) {
							asked = append(asked, name)
							return "CUSTOM01", true, nil
						},
					},
				},
			}},
		})

		driveEntityOp(t, client, w)
		credentialIs(t, w.api()[0].auth, "CUSTOM01")
		if 1 > len(asked) || "apikey" != asked[0] {
			t.Fatalf("the custom provider was asked %v, want [apikey ...]", asked)
		}
	})

	t.Run("a miss everywhere leaves the header off", func(t *testing.T) {
		os.Unsetenv(envprefix + "APIKEY")

		w := makewire()
		client := secretsClient(w, map[string]any{"feature": secretsOpts(nil)})

		driveEntityOp(t, client, w)
		call := w.api()[0]
		if call.has {
			t.Fatalf("a chain MISS must fall through to an unauthenticated request, got header %q", call.auth)
		}
	})

	t.Run("a provider ERROR fails the op and nothing reaches the wire", func(t *testing.T) {
		asked := false
		w := makewire()
		client := secretsClient(w, map[string]any{
			"feature": map[string]any{"secrets": map[string]any{
				"active": true,
				"providers": []any{
					&customProvider{
						lookup: func(name string) (string, bool, error) {
							asked = true
							return "", false, fmt.Errorf("vault unreachable")
						},
					},
				},
			}},
		})

		driveEntityOpUntil(t, client, "consulted the chain", func() bool {
			return asked
		})

		if 0 != len(w.api()) {
			t.Fatalf("a broken vault must never yield a request: %d calls went out", len(w.api()))
		}
	})

	t.Run("a provider recovers after a transient failure", func(t *testing.T) {
		calls := 0
		w := makewire()
		client := secretsClient(w, map[string]any{
			"feature": map[string]any{"secrets": map[string]any{
				"active": true,
				"providers": []any{
					&customProvider{
						lookup: func(name string) (string, bool, error) {
							calls++
							if 1 == calls {
								return "", false, fmt.Errorf("vault unreachable")
							}
							return "RECOVERED01", true, nil
						},
					},
				},
			}},
		})

		// First op fails closed; a failed resolution is never cached, so
		// the second op asks the chain again and succeeds.
		driveEntityOpUntil(t, client, "consulted the chain", func() bool {
			return 0 < calls
		})
		if 0 != len(w.api()) {
			t.Fatal("the first op must not reach the wire")
		}

		driveEntityOp(t, client, w)
		credentialIs(t, w.api()[0].auth, "RECOVERED01")
	})

	t.Run("auth nil suppresses the credential, chain or no chain", func(t *testing.T) {
		os.Setenv(envprefix+"APIKEY", "ENVKEY03")
		defer os.Unsetenv(envprefix + "APIKEY")

		w := makewire()
		client := secretsClient(w, map[string]any{
			"auth":    nil,
			"apikey":  "OPTKEY01",
			"feature": secretsOpts(nil),
		})

		driveEntityOp(t, client, w)

		// Nothing on the wire, even though the chain would have resolved:
		// go's vendored struct treats a stored null as "no value"
		// (fail-OPEN class), and makeOptions captures suppliedness before
		// validate and restores the null after - the guard this pins.
		call := w.api()[0]
		if call.has {
			t.Fatalf("auth nil must suppress the credential, got header %q", call.auth)
		}

		// The suppression survives option validation rather than being
		// replaced by the optspec's default auth map.
		opts := client.OptionsMap()
		authval, authgiven := opts["auth"]
		if !authgiven || nil != authval {
			t.Fatalf("options.auth must stay a present null, got (%v, present=%v)", authval, authgiven)
		}
	})
}

// A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
// feature used to override from the layer above.
//
// DEFAULT caching here, which is the whole point: `cache: true` is about
// holding a HIT, and holding the settled resolution after a miss meant the
// chain was never asked again for the life of the client. A secret
// provisioned after startup (a mounted file, a vault policy granted a
// minute late) was invisible forever, and the only workaround was giving up
// hit caching entirely.
func TestSecretsCachedMissIsReasked(t *testing.T) {
	var mu sync.Mutex
	calls := 0

	w := makewire()
	client := secretsClient(w, map[string]any{
		"feature": map[string]any{"secrets": map[string]any{
			"active": true,
			"providers": []any{
				&customProvider{
					lookup: func(name string) (string, bool, error) {
						mu.Lock()
						defer mu.Unlock()
						calls++
						// Absent on the first ask, present on the second.
						if 1 < calls {
							return "LATEKEY01", true, nil
						}
						return "", false, nil
					},
				},
			},
		}},
	})

	driveEntityOp(t, client, w)
	if first := w.api()[0]; first.has && "" != first.auth {
		t.Fatalf("the first resolve missed, so no credential should go out; got %q", first.auth)
	}

	driveEntityOp(t, client, w)
	credentialIs(t, w.api()[len(w.api())-1].auth, "LATEKEY01")

	mu.Lock()
	defer mu.Unlock()
	if 1 >= calls {
		t.Fatal("the chain was asked once and the MISS cached: a secret " +
			"that appears later can never be picked up")
	}
}

// The other half of the same rule: a HIT is still cached by default, so the
// fix above must not turn every request into a chain walk.
func TestSecretsCachedHitIsKept(t *testing.T) {
	var mu sync.Mutex
	calls := 0

	w := makewire()
	client := secretsClient(w, map[string]any{
		"feature": map[string]any{"secrets": map[string]any{
			"active": true,
			"providers": []any{
				&customProvider{
					lookup: func(name string) (string, bool, error) {
						mu.Lock()
						defer mu.Unlock()
						calls++
						return "STABLEKEY01", true, nil
					},
				},
			},
		}},
	})

	driveEntityOp(t, client, w)
	driveEntityOp(t, client, w)

	mu.Lock()
	defer mu.Unlock()
	if 1 != calls {
		t.Fatalf("a hit must be cached under the default cache: true, chain asked %d times", calls)
	}
}

// customProvider is a sekreto.Provider built in code (the interface is
// structural: Lookup + Describe).
type customProvider struct {
	lookup func(name string) (string, bool, error)
}

func (p *customProvider) Lookup(name string) (string, bool, error) {
	return p.lookup(name)
}

func (p *customProvider) Describe() string { return "custom:test" }

// ---------------------------------------------------------------------
// The access-token exchange.

func TestSecretsExchange(t *testing.T) {

	t.Run("the refresh token buys an access token, and a spent one is rebought once", func(t *testing.T) {
		os.Setenv(envprefix+"REFRESH_TOKEN", "REFRESH01")
		defer os.Unsetenv(envprefix + "REFRESH_TOKEN")

		// First API call is refused, the retry succeeds.
		w := makewire()
		w.apistatus = []int{401, 200}

		client := secretsClient(w, map[string]any{
			"feature": secretsOpts(map[string]any{
				"name":     "refresh_token",
				"exchange": map[string]any{"active": true},
			}),
		})

		driveEntityOp(t, client, w)

		if 2 != len(w.token()) {
			t.Fatalf("expected the initial purchase plus one rebuy, got %d", len(w.token()))
		}
		if !strings.Contains(w.token()[0].body, "REFRESH01") {
			t.Fatalf("the refresh token is sent in the request body, got %q", w.token()[0].body)
		}

		api := w.api()
		if 2 != len(api) {
			t.Fatalf("expected the request to be retried exactly once, got %d calls", len(api))
		}
		credentialIs(t, api[0].auth, "ACCESS01")
		// The retry must carry the NEW token, not the spent one.
		credentialIs(t, api[1].auth, "ACCESS02")
	})

	// `auth: nil` SUPPRESSES THE PURCHASE, not just the retry.
	//
	// resolve() runs before withrefresh's suppression check, so the refresh
	// token used to go to the token endpoint in a request body even here.
	// Stopping the retry does not unsend it - this asserts on the token
	// endpoint, which is the half the API-call assertions cannot see.
	t.Run("auth nil buys no token at all", func(t *testing.T) {
		os.Setenv(envprefix+"REFRESH_TOKEN", "REFRESH01")
		defer os.Unsetenv(envprefix + "REFRESH_TOKEN")

		w := makewire()
		w.apistatus = []int{401}

		client := secretsClient(w, map[string]any{
			"auth": nil,
			"feature": secretsOpts(map[string]any{
				"name":     "refresh_token",
				"exchange": map[string]any{"active": true},
			}),
		})

		driveEntityOp(t, client, w)

		if 0 != len(w.token()) {
			t.Fatalf("auth nil suppressed the credential but the refresh "+
				"token was still POSTed to the exchange endpoint (%d calls)",
				len(w.token()))
		}
		if call := w.api()[0]; call.has {
			t.Fatalf("no credential may be sent when auth is suppressed, got %q", call.auth)
		}
	})

	t.Run("test mode buys nothing and needs no token endpoint", func(t *testing.T) {
		os.Setenv(envprefix+"REFRESH_TOKEN", "REFRESH01")
		defer os.Unsetenv(envprefix + "REFRESH_TOKEN")

		w := makewire()
		client := withSecrets(func(extend bool) *sdk.UnivecSDK {
			opts := map[string]any{
				"system": map[string]any{"fetch": w.fetch},
				"feature": secretsOpts(map[string]any{
					"name":     "refresh_token",
					"exchange": map[string]any{"active": true},
				}),
			}
			if extend {
				opts["extend"] = []any{feat.NewSecretsFeature()}
			}
			return sdk.TestSDK(nil, opts)
		})

		driveEntityOpUntil(t, client, "resolved the fake token", func() bool {
			return "" != secretsFeatureOf(client).Credential()
		})

		if 0 != len(w.calls) {
			t.Fatalf("test mode must not do IO, saw %d calls", len(w.calls))
		}
		// A deterministic placeholder, so offline suites need no
		// configuration.
		if v := secretsFeatureOf(client).Credential(); "test-access_token" != v {
			t.Fatalf("expected the fake test token, got %q", v)
		}
	})
}

// ---------------------------------------------------------------------
// Review-hardening pins (vendor-tag rollout, PR review): the exchange
// works with ORDINARY options (no custom transport), the token body is
// real JSON, an uncached miss retracts the credential, and a failed
// resolution recovers safely under concurrency.

// The exchange with NO system.fetch: the raw fallback transport carries
// the purchase, and the body is MARSHALLED - a refresh token full of
// JSON-hostile characters must arrive as that literal value. End to end
// over real HTTP (httptest), token purchase and API call alike.
func TestSecretsExchangeRawFetch(t *testing.T) {
	tricky := "re\"fresh\\to\nken"

	var mu sync.Mutex
	gotrefresh := ""
	gotauth := ""

	srv := httptest.NewServer(http.HandlerFunc(func(res http.ResponseWriter, req *http.Request) {
		if strings.HasSuffix(req.URL.Path, "/auth/token") {
			var body map[string]any
			json.NewDecoder(req.Body).Decode(&body)
			mu.Lock()
			gotrefresh, _ = body["refresh_token"].(string)
			mu.Unlock()
			res.Header().Set("content-type", "application/json")
			res.Write([]byte(`{"access_token": "RAWTOK01"}`))
			return
		}
		mu.Lock()
		gotauth = req.Header.Get("authorization")
		mu.Unlock()
		res.Header().Set("content-type", "application/json")
		res.Write([]byte(`{}`))
	}))
	defer srv.Close()

	// No system.fetch anywhere: the API call takes the SDK's default
	// transport and the token purchase takes the feature's raw fallback.
	client := withSecrets(func(extend bool) *sdk.UnivecSDK {
		opts := map[string]any{
			"base": srv.URL + "/api",
			"feature": map[string]any{"secrets": map[string]any{
				"active":   true,
				"name":     "refresh_token",
				"exchange": map[string]any{"active": true, "refresh": tricky},
			}},
		}
		if extend {
			opts["extend"] = []any{feat.NewSecretsFeature()}
		}
		return sdk.NewUnivecSDK(opts)
	})

	driveEntityOpUntil(t, client, "reached the httptest server", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return "" != gotauth
	})

	mu.Lock()
	defer mu.Unlock()
	if tricky != gotrefresh {
		t.Fatalf("the refresh token must arrive as its literal value "+
			"(marshalled, not concatenated): want %q got %q", tricky, gotrefresh)
	}
	credentialIs(t, gotauth, "RAWTOK01")
}

// With `cache: false`, a provider that answered once and then reports a
// MISS (a revoked secret) must RETRACT the credential the feature wrote -
// prepareAuth must stop transmitting it.
func TestSecretsUncachedMissRetracts(t *testing.T) {
	var mu sync.Mutex
	have := true

	w := makewire()
	client := secretsClient(w, map[string]any{
		"feature": map[string]any{"secrets": map[string]any{
			"active": true,
			"cache":  false,
			"providers": []any{
				&customProvider{
					lookup: func(name string) (string, bool, error) {
						mu.Lock()
						defer mu.Unlock()
						if have {
							return "REVOCABLE01", true, nil
						}
						return "", false, nil
					},
				},
			},
		}},
	})

	driveEntityOp(t, client, w)
	credentialIs(t, w.api()[0].auth, "REVOCABLE01")

	mu.Lock()
	have = false
	mu.Unlock()

	driveEntityOp(t, client, w)
	last := w.api()[len(w.api())-1]
	if last.has && "" != last.auth {
		t.Fatalf("after the chain reports a miss, the retracted credential "+
			"must not go out; the wire saw %q", last.auth)
	}
}

// The RAW paths - Direct and Graphql - run no feature hooks at all, so
// for them the transport seam is the ONLY place resolution can happen.
// This is the pin that Direct gets the chain credential (and the same
// fail-closed refusal) without any entity pipeline involved.
func TestSecretsDirectPath(t *testing.T) {
	os.Setenv(envprefix+"APIKEY", "DIRECTKEY01")
	defer os.Unsetenv(envprefix + "APIKEY")

	w := makewire()
	client := secretsClient(w, map[string]any{
		"allow":   map[string]any{"op": "direct"},
		"feature": secretsOpts(nil),
	})

	res, err := client.Direct(map[string]any{"path": "/direct-probe"})
	if nil != err {
		t.Fatalf("direct failed: %v", err)
	}
	if ok, _ := res["ok"].(bool); !ok {
		t.Fatalf("direct refused: %v", res["err"])
	}
	if 1 != len(w.api()) {
		t.Fatalf("expected one direct call on the wire, got %d", len(w.api()))
	}
	credentialIs(t, w.api()[0].auth, "DIRECTKEY01")

	// And fail-closed holds for raw access too: a broken chain refuses
	// the Direct call before anything reaches the wire.
	broken := secretsClient(makewire(), map[string]any{
		"allow": map[string]any{"op": "direct"},
		"feature": map[string]any{"secrets": map[string]any{
			"active": true,
			"providers": []any{
				&customProvider{
					lookup: func(name string) (string, bool, error) {
						return "", false, fmt.Errorf("vault unreachable")
					},
				},
			},
		}},
	})
	res, err = broken.Direct(map[string]any{"path": "/direct-probe"})
	if nil != err {
		t.Fatalf("direct must report the refusal in-band: %v", err)
	}
	if ok, _ := res["ok"].(bool); ok {
		t.Fatal("a broken chain must refuse the raw path fail-closed")
	}
}

// FAIL CLOSED ON A CONSTRUCTION FAILURE. The chain a project configures
// can be wrong before a single lookup happens, and Init cannot fail the
// client construction the way ts's throwing init does - so it HOLDS the
// error (initerr) and the transport gate refuses to send.
//
// The entry pinned here is a bare kind name where a spec belongs. Init's
// type switch over the providers list had cases for a *ProviderSpec, a
// Provider and a map, and no default - so the entry was silently DROPPED,
// the chain got SHORTER rather than broken, and every request went out
// unauthenticated while the gate had nothing to refuse. That is fail-open
// by omission, and it survived every other case in this file because each
// of them configures the chain correctly.
//
// Both wire paths - the entity pipeline and Direct - each with a CONTROL
// leg through the SAME live transport, so a zero means REFUSED and not
// UNWIRED. The refusal is matched on sekreto's OWN message, so an
// unrelated failure cannot stand in for it.
func TestSecretsMalformedProviderEntry(t *testing.T) {
	// A kind NAME where a provider or spec belongs.
	malformed := []any{"hashicorp"}
	const notaprovider = "not a provider or a provider spec"

	workingchain := func(value string) map[string]any {
		return map[string]any{"secrets": map[string]any{
			"active": true,
			"providers": []any{
				&customProvider{
					lookup: func(name string) (string, bool, error) {
						if "apikey" == name {
							return value, true, nil
						}
						return "", false, nil
					},
				},
			},
		}}
	}
	malformedchain := map[string]any{"secrets": map[string]any{
		"active":    true,
		"providers": malformed,
	}}

	t.Run("fails the entity op and nothing reaches the wire", func(t *testing.T) {
		// CONTROL FIRST, so the zero below is known to be observable at all.
		control := makewire()
		ok := secretsClient(control, map[string]any{"feature": workingchain("INITKEY01")})
		driveEntityOp(t, ok, control)
		if 1 != len(control.api()) {
			t.Fatalf("the control operation did not reach system.fetch exactly once,"+
				" so this test cannot observe a request going out at all: got %d",
				len(control.api()))
		}
		credentialIs(t, control.api()[0].auth, "INITKEY01")

		// THE RULE.
		w := makewire()
		client := secretsClient(w, map[string]any{"feature": malformedchain})

		// The feature must still be INSTALLED: a construction failure that
		// silently uninstalled it would be the same fail-open by another
		// route, with nothing downstream gating anything.
		if nil == secretsFeatureOf(client) {
			t.Fatal("the secrets feature must stay installed on a construction failure")
		}

		// Every op the control leg could have taken: the gate sits at the
		// transport, so an op that never reached it proves nothing either way.
		driveEntityOpUntil(t, client, "was driven", func() bool { return true })

		if 0 != len(w.api()) {
			t.Fatalf("a malformed providers entry was DROPPED and the shortened chain"+
				" sent an UNAUTHENTICATED request: %d calls went out, first %q auth=%q",
				len(w.api()), w.api()[0].url, w.api()[0].auth)
		}
	})

	t.Run("fails Direct rather than sending, with sekreto's own message", func(t *testing.T) {
		// CONTROL FIRST.
		control := makewire()
		res, err := secretsClient(control, map[string]any{
			"allow":   map[string]any{"op": "direct"},
			"feature": workingchain("INITKEY01"),
		}).Direct(map[string]any{"path": "/thing"})
		if nil != err {
			t.Fatalf("the control request failed: %v", err)
		}
		if ok, _ := res["ok"].(bool); !ok {
			t.Fatalf("the control request was refused: %v", res["err"])
		}
		if 1 != len(control.api()) {
			t.Fatalf("the control request did not reach system.fetch exactly once,"+
				" so this test cannot observe a request going out at all: got %d",
				len(control.api()))
		}
		credentialIs(t, control.api()[0].auth, "INITKEY01")

		// THE RULE. Direct runs no feature hook at all, so the ONLY thing
		// that can refuse it is the transport gate.
		w := makewire()
		out, err := secretsClient(w, map[string]any{
			"allow":   map[string]any{"op": "direct"},
			"feature": malformedchain,
		}).Direct(map[string]any{"path": "/thing"})
		if nil != err {
			t.Fatalf("direct must report the refusal in-band: %v", err)
		}

		if 0 != len(w.api()) {
			t.Fatalf("a malformed providers entry was DROPPED and the shortened chain"+
				" sent an UNAUTHENTICATED direct request: %d calls went out, first %q auth=%q",
				len(w.api()), w.api()[0].url, w.api()[0].auth)
		}
		if ok, _ := out["ok"].(bool); ok {
			t.Fatal("a chain that could not be built must refuse the raw path fail-closed")
		}
		msg := fmt.Sprint(out["err"])
		if !strings.Contains(msg, notaprovider) {
			t.Fatalf("the refusal must carry sekreto's own message (%s), got: %s",
				notaprovider, msg)
		}
	})
}

// A provider failure closes the transport gate; a later retry that
// SUCCEEDS reopens it and every waiting operation goes out with the FRESH
// credential - never the stale pre-failure header, and never nothing.
func TestSecretsGateRecovery(t *testing.T) {
	var mu sync.Mutex
	mode := "fail"
	release := make(chan struct{})

	w := makewire()
	client := secretsClient(w, map[string]any{
		"feature": map[string]any{"secrets": map[string]any{
			"active": true,
			"cache":  false,
			"providers": []any{
				&customProvider{
					lookup: func(name string) (string, bool, error) {
						mu.Lock()
						m := mode
						mu.Unlock()
						if "fail" == m {
							return "", false, fmt.Errorf("vault unreachable")
						}
						if "slow" == m {
							<-release
						}
						return "FRESH01", true, nil
					},
				},
			},
		}},
	})

	// 1. The failure closes the gate: nothing reaches the wire.
	driveEntityOpUntil(t, client, "was refused by the gate", func() bool { return true })
	if 0 != len(w.api()) {
		t.Fatalf("a failed resolution must keep the wire silent, saw %d calls", len(w.api()))
	}

	// 2. Recovery under concurrency: two operations race the slow retry;
	// both must come out carrying the fresh credential.
	mu.Lock()
	mode = "slow"
	mu.Unlock()

	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			driveEntityOpUntil(t, client, "recovered", func() bool { return true })
		}()
	}
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(release)
	}()
	wg.Wait()

	for _, call := range w.api() {
		credentialIs(t, call.auth, "FRESH01")
	}
	if 0 == len(w.api()) {
		t.Fatal("recovery must let the operations out")
	}
}
