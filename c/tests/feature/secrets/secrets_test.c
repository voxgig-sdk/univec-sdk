// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the c port of tm/ts/test/feature/secrets/Secrets.test.ts, in the shape
// of tm/js/test/feature/secrets/Secrets.test.js and kotlin's SecretsTest.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because the feature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic. With
// the feature inactive nothing changes at all. With it active and the
// option unset, the chain (a memory store, a custom provider, a vault)
// supplies the credential instead.
//
// This file lives in the tests/feature/ container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`; the Makefile compiles it
// only when the feature is wired in (its generated kinds.mk exists).
//
// THE CLIENT IS LIVE AND THE TRANSPORT IS THE THING COUNTED. Every wire
// assertion here runs against a real client whose `options.system.fetch` is
// the recorder below - never `test_sdk`, whose test feature REPLACES the
// fetcher with its own in-memory mock and would leave a system.fetch
// counter at zero for a healthy SDK carrying no secrets feature at all. An
// assertion that cannot fail pins no rule, so each fail-closed case carries
// a CONTROL leg: the same construction with a WORKING provider must reach
// the same recorder exactly once, carrying the credential. Only then does
// a zero from the broken provider mean REFUSED rather than UNWIRED. And the
// refusal is matched on the PROVIDER'S OWN message, so an unrelated failure
// (a blocked op, a missing route) cannot stand in for fail-closed.
//
// Both raw paths (sdk_direct, sdk_graphql) are driven, because they run no
// feature hooks at all and are guarded ONLY by the transport wrapper. The
// entity pipeline is driven through the feature harness (feature_harness.h
// fh_op - the same miniature pipeline every other c feature test uses,
// since a template cannot name an entity), whose recorder is the Fetcher
// the wrapper wraps.
//
// NO ENVIRONMENT VARIABLES: the ts/go suites' `env` chains become `memory`
// chains and `custom` providers here. The rule under test - the chain
// answers when the option does not - is identical either way.

#include "feature_harness.h" /* test_sdk + Fetcher helpers + ctest.h */

#include "secrets.h"
#include "sekreto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int CASES = 0;
#define RUN(fn)                                                                 \
  do {                                                                         \
    CASES++;                                                                   \
    fn();                                                                      \
  } while (0)

// ---- the recording live transport ------------------------------------------

#define MAX_CALLS 16

typedef struct {
  // Every call, API and token endpoint alike: { url, fetchdef }.
  voxgig_value* calls;
  int api;    // API calls seen
  int token;  // token-endpoint calls seen
  // Status script for API calls, by API call index; 0 means 200.
  int64_t script[MAX_CALLS];
  // Tokens the endpoint answers, by token call index; NULL means "ACCESS0N".
  const char* tokens[MAX_CALLS];
  int64_t tokenstatus; // 0 means 200
  const char* tokenpath;  // substring that marks the token endpoint
  const char* tokenfield; // the response field name
} Rec;

static Rec* rec_new(void) {
  Rec* r = (Rec*)calloc(1, sizeof(Rec));
  r->calls = v_list();
  r->tokenpath = "/auth/token";
  r->tokenfield = "access_token";
  return r;
}

static voxgig_value* respond(int64_t status, voxgig_value* data) {
  return cmap(5,
    "status", v_num((double)status),
    "statusText", v_str(status >= 400 ? "ERR" : "OK"),
    "headers", v_map(),
    "json", json_thunk(data),
    "body", v_str("not-used"));
}

// args = [url, fetchdef], the system.fetch calling convention.
static voxgig_value* live_fetch(void* ud, voxgig_value* args) {
  Rec* r = (Rec*)ud;
  voxgig_value* urlv = voxgig_getelem(args, v_int(0), voxgig_new_undef());
  voxgig_value* fetchdef = voxgig_getelem(args, v_int(1), voxgig_new_undef());
  const char* url = voxgig_is_string(urlv) ? voxgig_as_string(urlv) : "";
  // A SNAPSHOT, not a share: the exchange rewrites the authorization header
  // of the SAME fetchdef in place before it retries, so a shared reference
  // would show the retry's token on the first attempt's record.
  voxgig_list_push(voxgig_as_list(r->calls),
                   cmap(2, "url", v_str(url), "fetchdef", voxgig_clone(fetchdef)));

  if (NULL != strstr(url, r->tokenpath)) {
    int n = r->token++;
    char buf[32];
    snprintf(buf, sizeof(buf), "ACCESS0%d", n + 1);
    const char* tok = (n < MAX_CALLS && r->tokens[n]) ? r->tokens[n] : buf;
    int64_t st = 0 == r->tokenstatus ? 200 : r->tokenstatus;
    return respond(st, cmap(1, r->tokenfield, v_str(tok)));
  }

  int n = r->api++;
  int64_t st = (n < MAX_CALLS && 0 != r->script[n]) ? r->script[n] : 200;
  return respond(st, cmap(2, "ok", v_bool(true), "n", v_num((double)n + 1)));
}

static voxgig_value* call_fetchdef(Rec* r, int i) {
  return getp(voxgig_getelem(r->calls, v_int(i), voxgig_new_undef()), "fetchdef");
}

// The authorization header of call i, or NULL when absent. Presence is read
// off the map directly: a present-but-EMPTY header is not suppression, and
// get_str alone cannot tell the two apart.
static const char* call_auth(Rec* r, int i, bool* present) {
  voxgig_value* headers = getp(call_fetchdef(r, i), "headers");
  if (present) {
    *present = voxgig_is_map(headers) &&
      NULL != voxgig_map_get(voxgig_as_map(headers), "authorization");
  }
  return get_str(headers, "authorization");
}

// The Authorization header carries the SPEC's credential prefix, which a
// TEMPLATE cannot know (a bearer scheme gives `Bearer <token>`, an apiKey
// scheme the raw token). So assert on the CREDENTIAL and let the prefix be
// whatever this SDK's API declares.
static bool credential_is(const char* header, const char* token) {
  if (NULL == header) return false;
  size_t hl = strlen(header);
  size_t tl = strlen(token);
  if (0 == strcmp(header, token)) return true;
  return hl > tl + 1 && ' ' == header[hl - tl - 1] && 0 == strcmp(header + hl - tl, token);
}

// ---- a LIVE client ----------------------------------------------------------

// A live-mode client whose system.fetch is the recorder. `secretsopts` is
// the feature's option map (active is forced true unless the map says
// otherwise); `extra` entries are merged into the top-level options
// (apikey, auth, ...).
static UnivecSDK* live(Rec* r, voxgig_value* secretsopts, voxgig_value* extra) {
  voxgig_value* fopts = voxgig_is_map(secretsopts) ? secretsopts : v_map();
  if (v_is_noval(getp(fopts, "active"))) setp(fopts, "active", v_bool(true));
  voxgig_value* opts = cmap(3,
    "base", v_str("http://api.test"),
    "system", cmap(1, "fetch", vfn(live_fetch, r)),
    "feature", cmap(1, "secrets", fopts));
  if (voxgig_is_map(extra)) {
    voxgig_map* m = voxgig_as_map(extra);
    for (size_t i = 0; i < m->len; i++) setp(opts, m->entries[i].key, m->entries[i].value);
  }
  return univec_sdk_new(opts);
}

static voxgig_value* direct(UnivecSDK* sdk) {
  PNError* err = NULL;
  voxgig_value* res = sdk_direct(sdk, cmap(2, "path", v_str("/thing"), "method", v_str("GET")), &err);
  CHECK(NULL == err, "sdk_direct never sets *err for a refused request");
  return res;
}

static bool res_ok(voxgig_value* res) {
  voxgig_value* okv = getp(res, "ok");
  return voxgig_is_bool(okv) && voxgig_as_bool(okv);
}

static const char* res_err(voxgig_value* res) {
  const char* e = get_str(res, "err");
  return e ? e : "";
}

// ---- providers --------------------------------------------------------------

static voxgig_value* memory(const char* name, const char* key, const char* value) {
  voxgig_value* spec = cmap(2, "kind", v_str("memory"), "values", cmap(1, key, v_str(value)));
  if (name) setp(spec, "name", v_str(name));
  return spec;
}

// A scripted custom provider: counts lookups, records the last name asked,
// fails the first `failfirst` lookups with its own message, then answers
// `value` (a miss when NULL).
typedef struct {
  int asked;
  char lastname[128];
  int failfirst;
  const char* value;
  const char* message;
} Custom;

static voxgig_value* custom_lookup(void* ud, voxgig_value* arg) {
  Custom* c = (Custom*)ud;
  c->asked++;
  snprintf(c->lastname, sizeof(c->lastname), "%s",
           voxgig_is_string(arg) ? voxgig_as_string(arg) : "(not a name)");
  if (c->asked <= c->failfirst) {
    return cmap(1, "__err__", v_str(c->message ? c->message : "vault unreachable"));
  }
  if (NULL == c->value) return v_undef();
  return v_str(c->value);
}

static Custom* custom_new(const char* value, int failfirst) {
  Custom* c = (Custom*)calloc(1, sizeof(Custom));
  c->value = value;
  c->failfirst = failfirst;
  return c;
}

static voxgig_value* custom_spec(Custom* c, const char* name) {
  voxgig_value* spec = cmap(2, "kind", v_str("custom"), "lookup", vfn(custom_lookup, c));
  if (name) setp(spec, "name", v_str(name));
  return spec;
}

static voxgig_value* providers1(voxgig_value* a) { return cmap(1, "providers", clist(1, a)); }

// ---- inactive ---------------------------------------------------------------

static void t_inactive_apikey_as_before(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, cmap(1, "active", v_bool(false)),
                             cmap(1, "apikey", v_str("OPTKEY01")));
  CHECK(NULL == sdk_feature_secrets(sdk), "inactive: no secrets feature is installed");
  voxgig_value* res = direct(sdk);
  CHECK(res_ok(res), "inactive: the request succeeds");
  CHECK_INT_EQ(r->api, 1, "inactive: the recorder IS the wire (control)");
  CHECK(credential_is(call_auth(r, 0, NULL), "OPTKEY01"), "inactive: apikey option is sent as before");
}

static void t_inactive_no_apikey_no_header(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, cmap(1, "active", v_bool(false)), v_map());
  direct(sdk);
  bool present = true;
  call_auth(r, 0, &present);
  CHECK_INT_EQ(r->api, 1, "inactive: one call");
  CHECK(!present, "inactive: no apikey means no authorization header");
}

// ---- active: the chain ------------------------------------------------------

static void t_apikey_wins_over_chain(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(memory("store", "APIKEY", "CHAIN01")),
                             cmap(1, "apikey", v_str("OPTKEY01")));
  Feature* f = sdk_feature_secrets(sdk);
  CHECK(NULL != f, "active: the feature is installed");
  CHECK(NULL == feature_secrets_initerr(f), "active: the chain built");
  direct(sdk);
  CHECK_INT_EQ(r->api, 1, "active: one call");
  CHECK(credential_is(call_auth(r, 0, NULL), "OPTKEY01"), "active: the apikey option wins over the chain");

  // The seat is a REAL store, not a special case: a directed read finds it.
  sek_sekreto* sek = feature_secrets_sekreto(f);
  char* got = NULL;
  sek_err e = sek_getfrom(sek, "options", "apikey", &got);
  CHECK(NULL == e, "active: the `options` store can be read directly");
  CHECK_STR_EQ(got, "OPTKEY01", "active: the `options` store holds the option");
}

static void t_omitted_apikey_defers(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(memory(NULL, "APIKEY", "CHAIN01")), v_map());
  direct(sdk);
  CHECK(credential_is(call_auth(r, 0, NULL), "CHAIN01"), "active: an OMITTED apikey defers to the chain");
  // The options map is FROZEN: the feature never writes the credential
  // into it, so the raw paths and the entity path agree by construction.
  voxgig_value* opts = sdk_options_map(sdk);
  const char* held = get_str(opts, "apikey");
  CHECK(NULL == held || '\0' == held[0], "active: options.apikey is never written by the feature");
  CHECK_STR_EQ(feature_secrets_credential(sdk_feature_secrets(sdk)), "CHAIN01",
               "active: the resolved credential is held by the feature");
}

static void t_empty_apikey_defers(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(memory(NULL, "APIKEY", "CHAIN01")),
                             cmap(1, "apikey", v_str("")));
  direct(sdk);
  CHECK(credential_is(call_auth(r, 0, NULL), "CHAIN01"), "active: an explicitly EMPTY apikey also defers");
}

static void t_auth_null_suppresses(void) {
  // Chain AND explicit apikey both set: suppression beats both.
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(memory(NULL, "APIKEY", "CHAIN01")),
                             cmap(2, "apikey", v_str("OPTKEY01"), "auth", voxgig_new_null()));
  voxgig_value* res = direct(sdk);
  CHECK(res_ok(res), "auth null: the request still goes out");
  CHECK_INT_EQ(r->api, 1, "auth null: one call");
  bool present = true;
  call_auth(r, 0, &present);
  CHECK(!present, "auth null: suppresses the credential, chain or no chain");
  // ...and the suppression survives make_options as a present null.
  voxgig_value* opts = sdk_options_map(sdk);
  voxgig_value* auth = voxgig_map_get(voxgig_as_map(opts), "auth");
  CHECK(NULL != auth && voxgig_is_null(auth), "auth null: options.auth survives as a present null");
}

static void t_custom_provider_verbatim(void) {
  // Both spellings: a bare FUNC, and the `custom` pseudo-kind map with a
  // store name a directed read can address.
  Rec* r = rec_new();
  Custom* bare = custom_new(NULL, 0);
  Custom* named = custom_new("CUSTOM01", 0);
  UnivecSDK* sdk = live(r,
    cmap(1, "providers", clist(2, vfn(custom_lookup, bare), custom_spec(named, "mine"))),
    v_map());
  Feature* f = sdk_feature_secrets(sdk);
  CHECK(NULL == feature_secrets_initerr(f), "custom: both entries joined the chain");
  direct(sdk);
  CHECK(credential_is(call_auth(r, 0, NULL), "CUSTOM01"), "custom: the provider's value reaches the wire");
  CHECK_STR_EQ(named->lastname, "apikey", "custom: asked for the configured secret name");
  CHECK_INT_EQ(bare->asked, 1, "custom: the bare FUNC was asked first (a miss, so the chain went on)");
  char* got = NULL;
  sek_err e = sek_getfrom(feature_secrets_sekreto(f), "mine", "apikey", &got);
  CHECK(NULL == e && NULL != got && 0 == strcmp(got, "CUSTOM01"), "custom: addressable by its store name");
}

static void t_miss_everywhere_no_header(void) {
  Rec* r = rec_new();
  Custom* c = custom_new(NULL, 0);
  UnivecSDK* sdk = live(r, providers1(custom_spec(c, NULL)), v_map());
  voxgig_value* res = direct(sdk);
  CHECK(res_ok(res), "miss: the op still runs");
  CHECK_INT_EQ(r->api, 1, "miss: one call");
  bool present = true;
  call_auth(r, 0, &present);
  CHECK(!present, "miss: a miss everywhere leaves the header off");
  CHECK_INT_EQ(c->asked, 1, "miss: the chain was asked");
}

// ---- active: fail closed ----------------------------------------------------

static void t_provider_error_fails_direct(void) {
  Rec* r = rec_new();
  Custom* broken = custom_new("NEVER", 99);
  broken->message = "vault unreachable";
  UnivecSDK* sdk = live(r, providers1(custom_spec(broken, NULL)), v_map());
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "error: direct() fails");
  CHECK(NULL != strstr(res_err(res), "vault unreachable"), "error: direct() carries the PROVIDER'S OWN message");
  CHECK_INT_EQ(r->api, 0, "error: nothing reached the wire");

  // CONTROL: the same construction with a working provider reaches the
  // same recorder exactly once, carrying the credential.
  Rec* r2 = rec_new();
  UnivecSDK* ok = live(r2, providers1(custom_spec(custom_new("CUSTOM01", 0), NULL)), v_map());
  CHECK(res_ok(direct(ok)), "control: the working chain succeeds");
  CHECK_INT_EQ(r2->api, 1, "control: the working chain reached the wire once");
  CHECK(credential_is(call_auth(r2, 0, NULL), "CUSTOM01"), "control: with the credential");
}

static voxgig_value* graphql(UnivecSDK* sdk) {
  PNError* err = NULL;
  voxgig_value* res = sdk_graphql(sdk, "{ thing { id } }", v_map(), v_map(), &err);
  CHECK(NULL == err, "sdk_graphql never sets *err for a refused request");
  return res;
}

static void t_provider_error_fails_graphql(void) {
  Rec* r = rec_new();
  Custom* broken = custom_new("NEVER", 99);
  broken->message = "vault unreachable";
  UnivecSDK* sdk = live(r, providers1(custom_spec(broken, NULL)), v_map());
  voxgig_value* res = graphql(sdk);
  CHECK(!res_ok(res), "error: graphql() fails");
  CHECK(NULL != strstr(res_err(res), "vault unreachable"), "error: graphql() carries the provider's own message");
  CHECK_INT_EQ(r->api, 0, "error: graphql sent nothing");

  Rec* r2 = rec_new();
  UnivecSDK* ok = live(r2, providers1(custom_spec(custom_new("CUSTOM01", 0), NULL)), v_map());
  CHECK(res_ok(graphql(ok)), "control: graphql with a working chain succeeds");
  CHECK_INT_EQ(r2->api, 1, "control: graphql reached the wire once");
  CHECK(credential_is(call_auth(r2, 0, NULL), "CUSTOM01"), "control: graphql carried the credential");
}

// The ENTITY pipeline, through the harness's miniature of it: the wrapper
// wraps the harness recorder, so a refusal here is the refusal every
// generated entity op gets from make_request.
static void t_provider_error_fails_entity_op(void) {
  voxgig_value* calls = NULL;
  Fetcher* server = fh_recorder(NULL, NULL, &calls);
  Custom* broken = custom_new("NEVER", 99);
  broken->message = "vault unreachable";
  FhFeat feats[1] = {{feature_secrets_new(), providers1(custom_spec(broken, NULL))}};
  FhHarness h = fh_make(server, feats, 1);
  FhOpSpec o;
  memset(&o, 0, sizeof(o));
  FhOpResult res = fh_op(&h, o);
  CHECK(!res.ok, "entity: the op fails");
  CHECK(NULL != res.err && NULL != res.err->msg && NULL != strstr(res.err->msg, "vault unreachable"),
        "entity: the op carries the provider's own message");
  CHECK_INT_EQ(rec_count(calls), 0, "entity: nothing reached the transport");

  voxgig_value* calls2 = NULL;
  Fetcher* server2 = fh_recorder(NULL, NULL, &calls2);
  FhFeat feats2[1] = {{feature_secrets_new(), providers1(custom_spec(custom_new("CUSTOM01", 0), NULL))}};
  FhHarness h2 = fh_make(server2, feats2, 1);
  FhOpResult res2 = fh_op(&h2, o);
  CHECK(res2.ok, "control: the entity op with a working chain succeeds");
  CHECK_INT_EQ(rec_count(calls2), 1, "control: the entity op reached the transport once");
  CHECK(credential_is(get_str(rec_headers(calls2, 0), "authorization"), "CUSTOM01"),
        "control: the entity op carried the credential");
}

static void t_recovers_after_transient_failure(void) {
  Rec* r = rec_new();
  Custom* flaky = custom_new("CUSTOM01", 1);
  UnivecSDK* sdk = live(r, providers1(custom_spec(flaky, NULL)), v_map());
  voxgig_value* first = direct(sdk);
  CHECK(!res_ok(first), "recover: the first request is refused");
  CHECK_INT_EQ(r->api, 0, "recover: nothing sent on the failure");
  voxgig_value* second = direct(sdk);
  CHECK(res_ok(second), "recover: a failed resolution is never cached - the next op asks again");
  CHECK_INT_EQ(r->api, 1, "recover: the second request went out");
  CHECK(credential_is(call_auth(r, 0, NULL), "CUSTOM01"), "recover: with the credential");
}

static void t_cache_false_asks_every_time(void) {
  Rec* r = rec_new();
  Custom* c = custom_new("CUSTOM01", 0);
  voxgig_value* fopts = providers1(custom_spec(c, NULL));
  setp(fopts, "cache", v_bool(false));
  UnivecSDK* sdk = live(r, fopts, v_map());
  direct(sdk);
  direct(sdk);
  CHECK_INT_EQ(c->asked, 2, "cache false: the chain is asked on every request");

  Rec* r2 = rec_new();
  Custom* c2 = custom_new("CUSTOM01", 0);
  UnivecSDK* cached = live(r2, providers1(custom_spec(c2, NULL)), v_map());
  direct(cached);
  direct(cached);
  CHECK_INT_EQ(c2->asked, 1, "cache true (default): the chain is asked once");
  CHECK_INT_EQ(r2->api, 2, "cache true: both requests went out");
}

static void t_cache_false_miss_retracts(void) {
  Rec* r = rec_new();
  Custom* c = custom_new("CUSTOM01", 0);
  voxgig_value* fopts = providers1(custom_spec(c, NULL));
  setp(fopts, "cache", v_bool(false));
  UnivecSDK* sdk = live(r, fopts, v_map());
  direct(sdk);
  CHECK(credential_is(call_auth(r, 0, NULL), "CUSTOM01"), "retract: the first request carries the hit");
  c->value = NULL; // the store no longer holds it
  direct(sdk);
  bool present = true;
  call_auth(r, 1, &present);
  CHECK(!present, "retract: an uncached miss after a hit takes the credential off the wire");
  CHECK_STR_EQ(feature_secrets_credential(sdk_feature_secrets(sdk)), "", "retract: the held credential is cleared");
}

static void t_secret_name_configurable(void) {
  Rec* r = rec_new();
  Custom* c = custom_new("TOKEN01", 0);
  voxgig_value* fopts = providers1(custom_spec(c, NULL));
  setp(fopts, "name", v_str("api.token"));
  UnivecSDK* sdk = live(r, fopts, v_map());
  direct(sdk);
  CHECK_STR_EQ(c->lastname, "api.token", "name: the configured secret name is what the chain is asked for");
  CHECK(credential_is(call_auth(r, 0, NULL), "TOKEN01"), "name: and its value is the credential");
}

static void t_sekreto_is_live(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r,
    providers1(cmap(2, "kind", v_str("memory"),
      "values", cmap(2, "APIKEY", v_str("CHAIN01"), "OTHER_SECRET", v_str("sesame-open")))),
    v_map());
  sek_sekreto* sek = feature_secrets_sekreto(sdk_feature_secrets(sdk));
  CHECK(NULL != sek, "live: the sekreto instance is exposed");
  char* got = NULL;
  sek_err e = sek_get(sek, "other.secret", &got);
  CHECK(NULL == e && NULL != got && 0 == strcmp(got, "sesame-open"), "live: arbitrary secrets resolve");
  char* red = sek_redact_text(sek, "the value sesame-open was logged");
  CHECK_STR_EQ(red, "the value [redacted] was logged", "live: redaction knows every resolved value");
}

static void t_unknown_kind_refused(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(cmap(1, "kind", v_str("nosuchkind"))), v_map());
  Feature* f = sdk_feature_secrets(sdk);
  const char* ie = feature_secrets_initerr(f);
  CHECK(NULL != ie && NULL != strstr(ie, "unknown provider kind: nosuchkind"),
        "init: an unknown kind is refused with sekreto's own message");
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "init: the request is refused");
  CHECK(NULL != strstr(res_err(res), "unknown provider kind"), "init: the refusal carries sekreto's message");
  CHECK_INT_EQ(r->api, 0, "init: nothing reached the wire");
  CHECK(res_ok(graphql(sdk)) == false && r->api == 0, "init: graphql is refused too");

  Rec* r2 = rec_new();
  UnivecSDK* ok = live(r2, providers1(memory(NULL, "APIKEY", "CHAIN01")), v_map());
  CHECK(res_ok(direct(ok)) && 1 == r2->api, "control: a known kind reaches the wire once");
}

static void t_malformed_entry_never_dropped(void) {
  // A bare kind name where a spec map was meant, AFTER a working store: the
  // chain must not be quietly shortened to the working store.
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r,
    cmap(1, "providers", clist(2, memory(NULL, "APIKEY", "CHAIN01"), v_str("hashicorp"))),
    v_map());
  const char* ie = feature_secrets_initerr(sdk_feature_secrets(sdk));
  CHECK(NULL != ie && NULL != strstr(ie, "not a provider or a provider spec"),
        "malformed: a bare string entry is refused, not dropped");
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res) && NULL != strstr(res_err(res), "not a provider or a provider spec"),
        "malformed: the request is refused with the message");
  CHECK_INT_EQ(r->api, 0, "malformed: nothing sent");

  // A number, and a `custom` map with no callable.
  Rec* r2 = rec_new();
  UnivecSDK* num = live(r2, providers1(v_num(42)), v_map());
  CHECK(!res_ok(direct(num)) && 0 == r2->api, "malformed: a numeric entry is refused");
  Rec* r3 = rec_new();
  UnivecSDK* nolookup = live(r3, providers1(cmap(1, "kind", v_str("custom"))), v_map());
  CHECK(!res_ok(direct(nolookup)) && 0 == r3->api, "malformed: a custom entry without a lookup is refused");

  Rec* r4 = rec_new();
  UnivecSDK* ok = live(r4, providers1(memory(NULL, "APIKEY", "CHAIN01")), v_map());
  CHECK(res_ok(direct(ok)) && 1 == r4->api, "control: the well-formed store alone reaches the wire once");
}

static void t_selected_kinds_in_vocabulary(void) {
  // The definitions the model selected are what the chain can build. This
  // file cannot know which groups a project chose, so it checks the
  // contract from both sides: every selected definition is in the live
  // catalog, and a kind NOT selected is refused by name (see the unknown
  // kind case). With no group selected the list is empty and only the
  // four built-ins remain.
  size_t n = 0;
  void** defs = feature_plugins("secrets", &n);
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(memory(NULL, "APIKEY", "CHAIN01")), v_map());
  Catalog* cat = sek_catalog(feature_secrets_sekreto(sdk_feature_secrets(sdk)));
  CHECK(catalog_has(cat, "memory") && catalog_has(cat, "env"), "vocabulary: the built-ins are always there");
  for (size_t i = 0; i < n; i++) {
    Definition* d = (Definition*)defs[i];
    CHECK(NULL != d && NULL != d->name, "vocabulary: a selected definition is a real one");
    CHECK(catalog_has(cat, d->name), "vocabulary: a selected kind is in the live catalog");
  }
  printf("secrets: %zu plugin definition(s) selected by the model\n", n);
  CHECK(0 == n || NULL != defs, "vocabulary: a non-empty count comes with a list");
}

static void t_raw_paths_get_chain_credential(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, providers1(memory(NULL, "APIKEY", "CHAIN01")), v_map());
  CHECK(res_ok(direct(sdk)), "raw: direct succeeds");
  CHECK(res_ok(graphql(sdk)), "raw: graphql succeeds");
  CHECK_INT_EQ(r->api, 2, "raw: both raw paths reached the wire");
  CHECK(credential_is(call_auth(r, 0, NULL), "CHAIN01"), "raw: direct carries the chain credential");
  CHECK(credential_is(call_auth(r, 1, NULL), "CHAIN01"), "raw: graphql carries the chain credential");
}

// ---- the exchange -----------------------------------------------------------

static voxgig_value* exchange_opts(voxgig_value* providers, voxgig_value* xextra) {
  voxgig_value* x = cmap(1, "active", v_bool(true));
  if (voxgig_is_map(xextra)) {
    voxgig_map* m = voxgig_as_map(xextra);
    for (size_t i = 0; i < m->len; i++) setp(x, m->entries[i].key, m->entries[i].value);
  }
  return cmap(2, "providers", providers, "exchange", x);
}

static voxgig_value* refresh_store(void) { return clist(1, memory(NULL, "APIKEY", "REFRESH01")); }

static const char* call_body(Rec* r, int i) {
  const char* b = get_str(call_fetchdef(r, i), "body");
  return b ? b : "";
}

static void t_exchange_buys_and_carries(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), v_map());
  CHECK(res_ok(direct(sdk)), "exchange: the request succeeds");
  CHECK_INT_EQ(r->token, 1, "exchange: one token purchase");
  CHECK_INT_EQ(r->api, 1, "exchange: one API call");
  CHECK(NULL != strstr(call_body(r, 0), "\"refresh_token\":\"REFRESH01\""), "exchange: the purchase carries the refresh token, marshalled");
  CHECK(credential_is(call_auth(r, 1, NULL), "ACCESS01"), "exchange: the request carries the bought access token");
  CHECK(NULL != strstr(get_str(call_fetchdef(r, 0), "method"), "POST"), "exchange: the purchase is a POST");
}

static void t_exchange_explicit_refresh_wins(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), cmap(1, "refresh", v_str("REFRESH-OPT"))), v_map());
  direct(sdk);
  CHECK(NULL != strstr(call_body(r, 0), "REFRESH-OPT"), "exchange: exchange.refresh seats first and wins over the chain");
}

static void t_exchange_one_purchase_many_requests(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), v_map());
  direct(sdk); direct(sdk); direct(sdk);
  CHECK_INT_EQ(r->token, 1, "exchange: one purchase serves many requests");
  CHECK_INT_EQ(r->api, 3, "exchange: all three went out");
}

static void t_exchange_401_rebuys_and_retries(void) {
  Rec* r = rec_new();
  r->script[0] = 401;
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), v_map());
  voxgig_value* res = direct(sdk);
  CHECK(res_ok(res), "401: the retried request succeeds");
  CHECK_INT_EQ(r->api, 2, "401: the SAME request was tried again once");
  CHECK_INT_EQ(r->token, 2, "401: a second token was bought");
  // calls: 0 token, 1 api(401), 2 token, 3 api(200)
  CHECK(credential_is(call_auth(r, 1, NULL), "ACCESS01"), "401: the first attempt carried the first token");
  CHECK(credential_is(call_auth(r, 3, NULL), "ACCESS02"), "401: the retry carried the fresh token, rebuilt from auth.prefix");
}

static void t_exchange_retry_once_not_loop(void) {
  Rec* r = rec_new();
  r->script[0] = 401;
  r->script[1] = 401;
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), v_map());
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "retry budget: a second 401 on a fresh token is a real failure");
  CHECK_INT_EQ(to_int(getp(res, "status")), 401, "retry budget: the API's own status is answered");
  CHECK_INT_EQ(r->api, 2, "retry budget: two attempts, not a spin");
  CHECK_INT_EQ(r->token, 2, "retry budget: two purchases, not a spin");
}

static void t_exchange_other_status_not_expiry(void) {
  Rec* r = rec_new();
  r->script[0] = 403;
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), v_map());
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "403: not ok");
  CHECK_INT_EQ(r->api, 1, "403: a status outside exchange.statuses is not an expiry - no retry");
  CHECK_INT_EQ(r->token, 1, "403: no second purchase");
}

static void t_exchange_statuses_configurable(void) {
  Rec* r = rec_new();
  r->script[0] = 419;
  UnivecSDK* sdk = live(r,
    exchange_opts(refresh_store(), cmap(1, "statuses", clist(1, v_num(419)))), v_map());
  CHECK(res_ok(direct(sdk)), "statuses: a configured status is an expiry");
  CHECK_INT_EQ(r->api, 2, "statuses: retried once");
  CHECK_INT_EQ(r->token, 2, "statuses: rebought once");
}

static void t_exchange_fields_configurable(void) {
  Rec* r = rec_new();
  r->tokenpath = "/oauth/exchange";
  r->tokenfield = "token";
  UnivecSDK* sdk = live(r,
    exchange_opts(refresh_store(), cmap(3,
      "path", v_str("/oauth/exchange"), "request", v_str("grant"), "response", v_str("token"))),
    v_map());
  CHECK(res_ok(direct(sdk)), "fields: the configured endpoint and fields work");
  CHECK(NULL != strstr(get_str(voxgig_getelem(r->calls, v_int(0), voxgig_new_undef()), "url"), "http://api.test/oauth/exchange"),
        "fields: the token endpoint is relative to base");
  CHECK(NULL != strstr(call_body(r, 0), "\"grant\":\"REFRESH01\""), "fields: the request field name is configurable");
  CHECK(credential_is(call_auth(r, 1, NULL), "ACCESS01"), "fields: the response field name is configurable");
}

static void t_exchange_explicit_apikey_spent_first(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), cmap(1, "apikey", v_str("HELD01")));
  CHECK(res_ok(direct(sdk)), "held: the request succeeds");
  CHECK_INT_EQ(r->token, 0, "held: an explicit apikey is spent before anything is bought");
  CHECK(credential_is(call_auth(r, 0, NULL), "HELD01"), "held: the held access token went out");
}

static void t_exchange_expired_apikey_falls_through(void) {
  Rec* r = rec_new();
  r->script[0] = 401;
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), cmap(1, "apikey", v_str("STALE01")));
  CHECK(res_ok(direct(sdk)), "expired: the retry succeeds");
  CHECK_INT_EQ(r->token, 1, "expired: a stale held token falls through to ONE purchase");
  CHECK(credential_is(call_auth(r, 0, NULL), "STALE01"), "expired: the stale token was spent first");
  CHECK(credential_is(call_auth(r, 2, NULL), "ACCESS01"), "expired: the retry carried the bought token");
}

static void t_exchange_no_refresh_is_error(void) {
  Rec* r = rec_new();
  Custom* miss = custom_new(NULL, 0);
  UnivecSDK* sdk = live(r, exchange_opts(clist(1, custom_spec(miss, NULL)), v_undef()), v_map());
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "no refresh: the request fails");
  CHECK(NULL != strstr(res_err(res), "no refresh token"), "no refresh: with the feature's own message");
  CHECK_INT_EQ(r->api, 0, "no refresh: never an unauthenticated call");
  CHECK_INT_EQ(r->token, 0, "no refresh: nothing bought");

  Rec* r2 = rec_new();
  UnivecSDK* ok = live(r2, exchange_opts(refresh_store(), v_undef()), v_map());
  CHECK(res_ok(direct(ok)) && 1 == r2->api && 1 == r2->token, "control: a refresh token buys and sends once each");
}

static void t_exchange_failing_endpoint_surfaces_refusal(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), cmap(1, "apikey", v_str("STALE01")));
  r->script[0] = 401;
  r->tokenstatus = 500;
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "endpoint down: the request fails");
  CHECK_INT_EQ(to_int(getp(res, "status")), 401, "endpoint down: the API's refusal is answered, not the exchange error");
  CHECK_INT_EQ(r->token, 1, "endpoint down: one attempted purchase, no spin");
  CHECK_INT_EQ(r->api, 1, "endpoint down: no retry without a token");
}

static void t_exchange_auth_null_suppresses(void) {
  Rec* r = rec_new();
  r->script[0] = 401;
  UnivecSDK* sdk = live(r, exchange_opts(refresh_store(), v_undef()), cmap(1, "auth", voxgig_new_null()));
  voxgig_value* res = direct(sdk);
  CHECK(!res_ok(res), "auth null + exchange: the refusal stands");
  CHECK_INT_EQ(r->api, 1, "auth null + exchange: a refusal of a deliberately unauthenticated request is not retried");
  bool present = true;
  call_auth(r, r->token, &present); // the first API call follows any purchase
  CHECK(!present, "auth null + exchange: no credential on the wire, refusal or not");
}

static void t_exchange_off_leaves_feature_as_before(void) {
  Rec* r = rec_new();
  UnivecSDK* sdk = live(r,
    cmap(2, "providers", clist(1, memory(NULL, "APIKEY", "CHAIN01")), "exchange", cmap(1, "active", v_bool(false))),
    v_map());
  CHECK(res_ok(direct(sdk)), "exchange off: succeeds");
  CHECK_INT_EQ(r->token, 0, "exchange off: nothing bought");
  CHECK(credential_is(call_auth(r, 0, NULL), "CHAIN01"), "exchange off: the chain credential goes out as is");
}

static void t_exchange_test_mode_buys_nothing(void) {
  // A TEST-mode client (fh_make builds one) with the exchange on: the
  // feature answers a deterministic fake token and no token endpoint is
  // ever reached. The harness recorder is the whole transport, so a
  // purchase would be visible as a call it never gets.
  voxgig_value* calls = NULL;
  Fetcher* server = fh_recorder(NULL, NULL, &calls);
  FhFeat feats[1] = {{feature_secrets_new(), exchange_opts(refresh_store(), v_undef())}};
  FhHarness h = fh_make(server, feats, 1);
  FhOpSpec o;
  memset(&o, 0, sizeof(o));
  FhOpResult res = fh_op(&h, o);
  CHECK(res.ok, "test mode: the op succeeds");
  CHECK_INT_EQ(rec_count(calls), 1, "test mode: one call, and it is the API call");
  CHECK(credential_is(get_str(rec_headers(calls, 0), "authorization"), "test-access_token"),
        "test mode: buys nothing and carries the deterministic fake token");
  CHECK_INT_EQ(fh_track_int(feats[0].f, "buys"), 1, "test mode: counted as a (fake) purchase");
}

int main(void) {
  RUN(t_inactive_apikey_as_before);
  RUN(t_inactive_no_apikey_no_header);
  RUN(t_apikey_wins_over_chain);
  RUN(t_omitted_apikey_defers);
  RUN(t_empty_apikey_defers);
  RUN(t_auth_null_suppresses);
  RUN(t_custom_provider_verbatim);
  RUN(t_miss_everywhere_no_header);
  RUN(t_provider_error_fails_direct);
  RUN(t_provider_error_fails_graphql);
  RUN(t_provider_error_fails_entity_op);
  RUN(t_recovers_after_transient_failure);
  RUN(t_cache_false_asks_every_time);
  RUN(t_cache_false_miss_retracts);
  RUN(t_secret_name_configurable);
  RUN(t_sekreto_is_live);
  RUN(t_unknown_kind_refused);
  RUN(t_malformed_entry_never_dropped);
  RUN(t_selected_kinds_in_vocabulary);
  RUN(t_raw_paths_get_chain_credential);
  RUN(t_exchange_buys_and_carries);
  RUN(t_exchange_explicit_refresh_wins);
  RUN(t_exchange_one_purchase_many_requests);
  RUN(t_exchange_401_rebuys_and_retries);
  RUN(t_exchange_retry_once_not_loop);
  RUN(t_exchange_other_status_not_expiry);
  RUN(t_exchange_statuses_configurable);
  RUN(t_exchange_fields_configurable);
  RUN(t_exchange_explicit_apikey_spent_first);
  RUN(t_exchange_expired_apikey_falls_through);
  RUN(t_exchange_no_refresh_is_error);
  RUN(t_exchange_failing_endpoint_surfaces_refusal);
  RUN(t_exchange_auth_null_suppresses);
  RUN(t_exchange_off_leaves_feature_as_before);
  RUN(t_exchange_test_mode_buys_nothing);

  // The generator's runtime lane reads this line: a suite that RAN fewer
  // cases than it declares was trimmed, not passed.
  printf("secrets: ran %d case(s)\n", CASES);
  TEST_SUMMARY("secrets");
}
