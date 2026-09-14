// Univec SDK — behavioural tests for the secrets feature (vendored
// @voxgig/sekreto): the cpp port of tm/ts/test/feature/secrets/
// Secrets.test.ts, in the shape of tm/js/test/feature/secrets/Secrets.test.js
// and c's tests/feature/secrets/secrets_test.c.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because the feature places it FIRST in the provider chain
// (a `memory` store named `options`) - explicit-beats-lookup falls out of
// sekreto's first-hit rule rather than from special-case logic. With the
// feature inactive nothing changes at all. With it active and the option
// unset, the chain (a memory store, a custom provider, a vault) supplies the
// credential instead.
//
// This file lives in the test/feature/ container on purpose: `target add`
// trims it, along with the feature header and the vendored library, for a
// project whose model does not select `secrets`; the Makefile compiles it
// only when the feature is wired in (feature/secrets/kinds.cpp exists).
//
// THE CLIENT IS LIVE AND THE TRANSPORT IS THE THING COUNTED. Every wire
// assertion here runs against a real UnivecSDK whose
// `options.system.fetch` is the recorder below - never testSDK(), whose test
// feature REPLACES the fetcher with its own in-memory mock and would leave a
// system.fetch counter at zero for a healthy SDK carrying no secrets feature
// at all. An assertion that cannot fail pins no rule, so each fail-closed
// case carries a CONTROL leg: the same construction with a WORKING provider
// must reach the same recorder exactly once, carrying the credential. Only
// then does a zero from the broken provider mean REFUSED rather than
// UNWIRED. And the refusal is matched on the PROVIDER'S OWN message, so an
// unrelated failure (a blocked op, a missing route) cannot stand in for
// fail-closed.
//
// Both raw paths (direct, graphql) are driven, because they run no feature
// hooks at all and are guarded ONLY by the transport wrapper. The entity
// pipeline is driven through the feature harness (test/harness.hpp fhMake -
// the same miniature pipeline every other cpp feature test uses, since a
// template cannot name an entity), whose recorder is the Fetcher the wrapper
// wraps; that is also the direct-construction vehicle cpp has instead of
// `extend`.
//
// NO ENVIRONMENT VARIABLES, NO NETWORK: the ts/go suites' `env` chains
// become `memory` chains and `custom` providers here, and the provider that
// ERRORS is a `dotenv` pointed at a directory (readfile answers EISDIR, which
// sekreto reports as a FAILURE, never a MISS). The rule under test - the
// chain answers when the option does not, and a store that cannot answer
// fails the op - is identical either way.

#include "../../harness.hpp"

#include "../../../feature/secrets.hpp"

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

using namespace sdk;
using namespace sdk::fh;

static int CASES = 0;
#define RUN(fn)  \
  do {           \
    CASES++;     \
    T_RUN(fn);   \
  } while (0)

// ---- the recording live transport ------------------------------------------

struct Rec {
  std::vector<Value> calls;   // every call, API and token endpoint alike
  int api = 0;                // API calls seen
  int token = 0;              // token-endpoint calls seen
  std::vector<int> script;    // status per API call index; missing/0 means 200
  std::vector<std::string> tokens; // token per token call; missing means ACCESS0N
  int tokenstatus = 0;        // 0 means 200
  std::string tokenpath = "/auth/token";
  std::string tokenfield = "access_token";

  Value fetch(const std::string& url, const Value& fetchdef) {
    // SNAPSHOT the fetchdef: the exchange retry rewrites the authorization
    // header of the same map in place (as go does), so a recorded reference
    // would show every attempt carrying the LAST token.
    calls.push_back(vmap({{"url", Value(url)}, {"fetchdef", Struct::clone(fetchdef)}}));

    if (std::string::npos != url.find(tokenpath)) {
      int n = ++token;
      std::string tok = (n <= (int)tokens.size() && !tokens[n - 1].empty())
        ? tokens[n - 1] : "ACCESS0" + std::to_string(n);
      int status = 0 == tokenstatus ? 200 : tokenstatus;
      return fhResponse(status, vmap({{tokenfield, Value(tok)}}), Value::undef());
    }

    int n = ++api;
    int status = (n <= (int)script.size() && 0 != script[n - 1]) ? script[n - 1] : 200;
    return fhResponse(status, vmap({{"ok", Value(true)}, {"n", Value(n)}}), Value::undef());
  }

  // The authorization header the i-th call left with ("" when none).
  std::string auth(size_t i) const {
    if (i >= calls.size()) return "";
    Value fd = getp(calls[i], "fetchdef");
    Value h = getp(fd, "headers");
    Value a = getp(h, "authorization");
    return a.is_string() ? a.as_string() : "";
  }

  bool hasAuth(size_t i) const {
    if (i >= calls.size()) return false;
    Value h = getp(getp(calls[i], "fetchdef"), "headers");
    return h.is_map() && !mapget(h, "authorization").is_undef();
  }

  std::string body(size_t i) const {
    if (i >= calls.size()) return "";
    Value b = getp(getp(calls[i], "fetchdef"), "body");
    return b.is_string() ? b.as_string() : Struct::stringify(b);
  }

  std::string url(size_t i) const {
    if (i >= calls.size()) return "";
    return as_str(getp(calls[i], "url"));
  }
};

static Value recFetch(std::shared_ptr<Rec> rec) {
  vs::Injector fn = [rec](vs::Injection&, const Value& args, const std::string&,
                          const Value&) -> Value {
    Value url = vs::getelem(args, Value(int64_t(0)));
    Value fetchdef = vs::getelem(args, Value(int64_t(1)));
    return rec->fetch(url.is_string() ? url.as_string() : "", fetchdef);
  };
  return Value(fn);
}

// A LIVE client: the recorder is system.fetch, the secrets feature comes
// from the generated makeFeature("secrets") through the options - the only
// route that proves the model wiring. `extra` lands at the top level of the
// options (apikey, auth).
static std::shared_ptr<UnivecSDK> liveClient(std::shared_ptr<Rec> rec, const Value& fopts,
                                                  const Value& extra = Value::undef()) {
  Value opts = vmap({
    {"base", Value(std::string("http://api.test"))},
    {"system", vmap({{"fetch", recFetch(rec)}})}});
  if (fopts.is_map()) map_put(opts, "feature", vmap({{"secrets", fopts}}));
  if (extra.is_map()) {
    for (const auto& kv : *extra.as_map()) map_put(opts, kv.first, kv.second);
  }
  return std::make_shared<UnivecSDK>(opts);
}

static Value memoryProvider(const std::string& key, const std::string& value) {
  return vmap({{"kind", Value(std::string("memory"))},
               {"values", vmap({{key, Value(value)}})}});
}

// A provider that ERRORS on lookup with no network: dotenv reading a
// DIRECTORY. readfile opens it fine and read(2) fails with EISDIR, which the
// port reports as Readstate::Failed - an ERROR, never a MISS.
static Value brokenProvider() {
  return vmap({{"kind", Value(std::string("dotenv"))}, {"file", Value(std::string("/"))}});
}
static const char* BROKEN_MSG = "sekreto: dotenv provider cannot read /";

static Value secretsOpts(const Value& providers, const Value& more = Value::undef()) {
  Value o = vmap({{"active", Value(true)}});
  if (providers.is_list()) map_put(o, "providers", providers);
  if (more.is_map()) {
    for (const auto& kv : *more.as_map()) map_put(o, kv.first, kv.second);
  }
  return o;
}

// The header prepareAuth would build for this client and token: the model
// decides the prefix, so it is read off the live options rather than assumed.
static std::string expectAuth(SdkClient* client, const std::string& token) {
  std::string prefix = as_str(Struct::getpath(client->options, {"auth", "prefix"}));
  return prefix.empty() ? token : prefix + " " + token;
}

static Value direct(std::shared_ptr<UnivecSDK> client) {
  return client->direct(vmap({{"path", Value(std::string("/thing"))},
                              {"method", Value(std::string("GET"))}}));
}

static bool okOf(const Value& res) { return is_true(getp(res, "ok")); }
static std::string errOf(const Value& res) { return as_str(getp(getp(res, "err"), "message")); }
static bool contains(const std::string& hay, const std::string& needle) {
  return std::string::npos != hay.find(needle);
}

// A custom provider Injector over a small script: answers `values[i]` on the
// i-th call ("" -> MISS, "!msg" -> ERROR msg), the last entry repeating.
struct Script {
  std::vector<std::string> values;
  int calls = 0;
};
static Value scripted(std::shared_ptr<Script> s) {
  vs::Injector fn = [s](vs::Injection&, const Value&, const std::string&, const Value&) -> Value {
    int n = s->calls++;
    if (s->values.empty()) return Value::undef();
    const std::string& v = s->values[std::min<size_t>(n, s->values.size() - 1)];
    if (v.empty()) return Value::undef();
    if ('!' == v[0]) return vmap({{"__err__", Value(v.substr(1))}});
    return Value(v);
  };
  return Value(fn);
}

// ---- inactive: nothing changes -----------------------------------------------

static void t_inactive_apikey_as_before() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, vmap({{"active", Value(false)}}),
                           vmap({{"apikey", Value(std::string("K1"))}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "inactive: direct failed: " + errOf(res));
  ASSERT_EQ(rec->api, 1, "inactive: one API call");
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "K1"), "inactive: apikey header as before");
  ASSERT_TRUE(nullptr == SecretsFeature::of(client.get()) ||
              !SecretsFeature::of(client.get())->getActive(),
              "inactive: feature must not be active");
}

static void t_inactive_no_apikey_no_header() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, vmap({{"active", Value(false)}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "inactive: direct failed: " + errOf(res));
  ASSERT_EQ(rec->api, 1, "inactive: one API call");
  ASSERT_FALSE(rec->hasAuth(0), "inactive: no apikey means no header");
}

// ---- the apikey option keeps its meaning ------------------------------------

static void t_apikey_wins_over_chain() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})),
                           vmap({{"apikey", Value(std::string("K1"))}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "apikey wins: direct failed: " + errOf(res));
  ASSERT_EQ(rec->api, 1, "apikey wins: one API call");
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "K1"), "apikey wins: the OPTION is on the wire");
  auto f = SecretsFeature::of(client.get());
  ASSERT_NOTNULL(f, "apikey wins: feature installed");
  if (f) ASSERT_EQ(f->credential(), std::string("K1"), "apikey wins: resolved credential");
}

static void t_omitted_apikey_defers() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "defers: direct failed: " + errOf(res));
  ASSERT_EQ(rec->api, 1, "defers: one API call");
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "CHAINKEY"), "defers: the CHAIN is on the wire");
}

static void t_empty_apikey_defers() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})),
                           vmap({{"apikey", Value(std::string(""))}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "empty apikey: direct failed: " + errOf(res));
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "CHAINKEY"),
            "empty apikey: an explicitly empty option defers to the chain");
}

static void t_auth_null_suppresses() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})),
                           vmap({{"auth", Value(nullptr)}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "auth null: direct failed: " + errOf(res));
  ASSERT_EQ(rec->api, 1, "auth null: the op still proceeds");
  ASSERT_FALSE(rec->hasAuth(0), "auth null: NO header even though the chain resolved");
  auto f = SecretsFeature::of(client.get());
  if (f) ASSERT_EQ(f->credential(), std::string("CHAINKEY"),
                   "auth null: the chain still resolved (suppression is at the header)");
}

static void t_custom_provider_verbatim() {
  auto rec = std::make_shared<Rec>();
  auto s = std::make_shared<Script>();
  s->values = {"CUSTOMKEY"};
  auto client = liveClient(rec, secretsOpts(vlist({scripted(s)})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "custom: direct failed: " + errOf(res));
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "CUSTOMKEY"), "custom: a bare callable is a provider");

  // The map form, named, with a memory store behind it.
  auto rec2 = std::make_shared<Rec>();
  auto s2 = std::make_shared<Script>();
  s2->values = {""}; // a MISS
  auto client2 = liveClient(rec2, secretsOpts(vlist({
    vmap({{"kind", Value(std::string("custom"))}, {"lookup", scripted(s2)},
          {"name", Value(std::string("mine"))}}),
    memoryProvider("APIKEY", "BEHIND")})));
  Value res2 = direct(client2);
  ASSERT_TRUE(okOf(res2), "custom miss: direct failed: " + errOf(res2));
  ASSERT_EQ(rec2->auth(0), expectAuth(client2.get(), "BEHIND"),
            "custom miss: a MISS falls through to the next store");
  ASSERT_EQ(s2->calls, 1, "custom miss: the custom provider was asked");
}

static void t_miss_everywhere_no_header() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("OTHER", "X")})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "miss: direct failed: " + errOf(res));
  ASSERT_EQ(rec->api, 1, "miss: the op proceeds");
  ASSERT_FALSE(rec->hasAuth(0), "miss: a miss everywhere sends no header");
}

// ---- fail-closed: a provider ERROR never degrades into an unauthenticated send

static void t_provider_error_fails_direct() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({brokenProvider()})));
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "error: direct must FAIL");
  ASSERT_TRUE(contains(errOf(res), BROKEN_MSG),
              "error: the refusal carries the PROVIDER'S OWN message, got: " + errOf(res));
  ASSERT_EQ(rec->api, 0, "error: NOTHING left the process");

  // CONTROL: the same construction with a working store reaches the same
  // recorder exactly once, carrying the credential.
  auto crec = std::make_shared<Rec>();
  auto cclient = liveClient(crec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})));
  Value cres = direct(cclient);
  ASSERT_TRUE(okOf(cres), "error control: direct failed: " + errOf(cres));
  ASSERT_EQ(crec->api, 1, "error control: exactly one call reached the transport");
  ASSERT_EQ(crec->auth(0), expectAuth(cclient.get(), "CHAINKEY"), "error control: with the credential");
}

static void t_provider_error_fails_graphql() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({brokenProvider()})));
  Value res = client->graphql("query { thing { id } }");
  ASSERT_FALSE(okOf(res), "error: graphql must FAIL");
  ASSERT_TRUE(contains(errOf(res), BROKEN_MSG),
              "error: graphql refusal carries the provider's message, got: " + errOf(res));
  ASSERT_EQ(rec->api, 0, "error: graphql sent nothing");

  auto crec = std::make_shared<Rec>();
  auto cclient = liveClient(crec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})));
  Value cres = cclient->graphql("query { thing { id } }");
  ASSERT_TRUE(okOf(cres), "error control: graphql failed: " + errOf(cres));
  ASSERT_EQ(crec->api, 1, "error control: graphql reached the transport once");
  ASSERT_EQ(crec->auth(0), expectAuth(cclient.get(), "CHAINKEY"), "error control: graphql credential");
}

// The ENTITY pipeline, through the harness (direct construction - cpp's
// stand-in for `extend`): fhMake installs the recorder as the utility's
// fetcher, then init wraps it, so h->op crosses the wrapper.
static void t_provider_error_fails_entity_op() {
  auto rec = std::make_shared<FhRecorder>();
  auto server = [rec](CtxPtr ctx, const std::string& url, const Value& fd) {
    return rec->fetch(ctx, url, fd);
  };
  auto h = fhMake(server, {fhF(std::make_shared<SecretsFeature>(),
                              fhMap({{"providers", vlist({brokenProvider()})}}))});
  FhOpResult r = h->op(fhOp("load"));
  ASSERT_FALSE(r.ok, "entity: the op must FAIL");
  ASSERT_TRUE(r.err && contains(r.err->msg, BROKEN_MSG),
              "entity: the refusal carries the provider's message, got: " +
              (r.err ? r.err->msg : std::string("(none)")));
  ASSERT_EQ(rec->calls.size(), (size_t)0, "entity: NOTHING left the pipeline");

  auto crec = std::make_shared<FhRecorder>();
  auto cserver = [crec](CtxPtr ctx, const std::string& url, const Value& fd) {
    return crec->fetch(ctx, url, fd);
  };
  auto ch = fhMake(cserver, {fhF(std::make_shared<SecretsFeature>(),
                                fhMap({{"providers", vlist({memoryProvider("APIKEY", "CHAINKEY")})}}))});
  FhOpResult cr = ch->op(fhOp("load"));
  ASSERT_TRUE(cr.ok, "entity control: op failed: " + (cr.err ? cr.err->msg : std::string("")));
  ASSERT_EQ(crec->calls.size(), (size_t)1, "entity control: exactly one call");
  Value auth = getp(crec->headers(0), "authorization");
  ASSERT_EQ(as_str(auth), expectAuth(ch->client.get(), "CHAINKEY"),
            "entity control: the chain credential reached the header");
}

static void t_recovers_after_transient_failure() {
  auto rec = std::make_shared<Rec>();
  auto s = std::make_shared<Script>();
  s->values = {"!sekreto: vault is down", "BACK"};
  auto client = liveClient(rec, secretsOpts(vlist({scripted(s)})));
  Value first = direct(client);
  ASSERT_FALSE(okOf(first), "transient: the first request fails");
  ASSERT_TRUE(contains(errOf(first), "sekreto: vault is down"), "transient: with the provider's message");
  ASSERT_EQ(rec->api, 0, "transient: nothing sent while failed");
  Value second = direct(client);
  ASSERT_TRUE(okOf(second), "transient: a failure is never cached: " + errOf(second));
  ASSERT_EQ(rec->api, 1, "transient: the second request went out");
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "BACK"), "transient: with the recovered credential");
}

// ---- caching ---------------------------------------------------------------------

static void t_cache_false_asks_every_time() {
  auto rec = std::make_shared<Rec>();
  auto s = std::make_shared<Script>();
  s->values = {"K"};
  auto client = liveClient(rec, secretsOpts(vlist({scripted(s)}), vmap({{"cache", Value(false)}})));
  direct(client); direct(client); direct(client);
  ASSERT_EQ(rec->api, 3, "cache false: three calls");
  ASSERT_EQ(s->calls, 3, "cache false: the chain is asked once per REQUEST");

  auto rec2 = std::make_shared<Rec>();
  auto s2 = std::make_shared<Script>();
  s2->values = {"K"};
  auto client2 = liveClient(rec2, secretsOpts(vlist({scripted(s2)})));
  direct(client2); direct(client2); direct(client2);
  ASSERT_EQ(rec2->api, 3, "cache true: three calls");
  ASSERT_EQ(s2->calls, 1, "cache true (default): the chain is asked once");
}

static void t_cache_false_miss_retracts() {
  auto rec = std::make_shared<Rec>();
  auto s = std::make_shared<Script>();
  s->values = {"K", ""}; // a hit, then revoked
  auto client = liveClient(rec, secretsOpts(vlist({scripted(s)}), vmap({{"cache", Value(false)}})));
  direct(client);
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "K"), "retract: first request carries the hit");
  direct(client);
  ASSERT_EQ(rec->api, 2, "retract: the second request still goes (a miss is not an error)");
  ASSERT_FALSE(rec->hasAuth(1), "retract: an uncached MISS after a hit stops the old value going out");
}

static void t_secret_name_configurable() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("API_TOKEN", "T1")}),
                                            vmap({{"name", Value(std::string("api.token"))}})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "name: direct failed: " + errOf(res));
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "T1"), "name: `api.token` reads API_TOKEN");
}

static void t_chain_is_live() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY"),
                                                   memoryProvider("OTHER_SECRET", "SECRET02")})));
  auto f = SecretsFeature::of(client.get());
  ASSERT_NOTNULL(f, "live: feature installed");
  if (!f) return;
  ASSERT_TRUE(f->initError().empty(), "live: no init error: " + f->initError());
  auto chain = f->chain();
  ASSERT_NOTNULL(chain, "live: the chain is exposed");
  if (!chain) return;
  std::optional<std::string> other = chain->tryget("other.secret");
  ASSERT_TRUE(other.has_value() && "SECRET02" == other.value(), "live: arbitrary secrets through the same chain");
  // Only values of four characters or more are redacted (sekreto's rule).
  ASSERT_EQ(chain->redact("token SECRET02 here"), std::string("token [redacted] here"), "live: redaction");
  ASSERT_EQ(f->credential(), std::string(""), "live: nothing resolved before a request");
  direct(client);
  ASSERT_EQ(f->credential(), std::string("CHAINKEY"), "live: the credential after a request");
  ASSERT_EQ(f->track().resolves, 1LL, "live: one resolution");
}

// ---- construction failures refuse to send -------------------------------------

static void t_unknown_kind_refused() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({
    vmap({{"kind", Value(std::string("nosuchkind"))}})})));
  auto f = SecretsFeature::of(client.get());
  ASSERT_NOTNULL(f, "unknown kind: feature installed");
  if (f) ASSERT_TRUE(contains(f->initError(), "sekreto: unknown provider kind: nosuchkind"),
                     "unknown kind: sekreto's own message, got: " + f->initError());
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "unknown kind: direct refused");
  ASSERT_TRUE(contains(errOf(res), "sekreto: unknown provider kind: nosuchkind"),
              "unknown kind: the refusal is sekreto's, got: " + errOf(res));
  ASSERT_EQ(rec->api, 0, "unknown kind: NOTHING left the process (wrap-first)");

  // A shipped PLUGIN kind this model did not select is refused with the
  // hint that names the fix - checked against the vocabulary this SDK
  // actually has, so the case holds whatever groups the model turned on.
  std::vector<std::string> selected;
  for (const auto& erased : featurePlugins("secrets")) {
    selected.push_back(std::static_pointer_cast<plugin::Definition>(erased)->name);
  }
  std::string unselected;
  for (const std::string& kind : sekreto::KINDS().plugin) {
    if (selected.end() == std::find(selected.begin(), selected.end(), kind)) {
      unselected = kind;
      break;
    }
  }
  if (!unselected.empty()) {
    auto rec2 = std::make_shared<Rec>();
    auto client2 = liveClient(rec2, secretsOpts(vlist({
      vmap({{"kind", Value(unselected)}, {"addr", Value(std::string("https://127.0.0.1:9"))},
            {"token", Value(std::string("t"))}})})));
    Value res2 = direct(client2);
    ASSERT_FALSE(okOf(res2), "unselected plugin kind: refused");
    ASSERT_TRUE(contains(errOf(res2), unselected + " is a sekreto plugin, not built in: pass it in the plugins option"),
                "unselected plugin kind: the hint names the fix, got: " + errOf(res2));
    ASSERT_EQ(rec2->api, 0, "unselected plugin kind: nothing sent");
  }
}

static void t_malformed_entry_never_dropped() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY"), Value(42)})));
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "malformed: a bad entry fails the chain, never shortens it");
  ASSERT_TRUE(contains(errOf(res), "sekreto: not a provider or a provider spec: 42"),
              "malformed: sekreto's own wording, got: " + errOf(res));
  ASSERT_EQ(rec->api, 0, "malformed: nothing sent");

  auto rec2 = std::make_shared<Rec>();
  auto client2 = liveClient(rec2, secretsOpts(vlist({
    vmap({{"kind", Value(std::string("custom"))}})})));
  Value res2 = direct(client2);
  ASSERT_FALSE(okOf(res2), "malformed custom: refused");
  ASSERT_TRUE(contains(errOf(res2), "sekreto: not a provider or a provider spec:") &&
              contains(errOf(res2), "needs a `lookup` callable"),
              "malformed custom: says what is missing, got: " + errOf(res2));
  ASSERT_EQ(rec2->api, 0, "malformed custom: nothing sent");

  // CONTROL: the same chain without the bad entry sends once with the key.
  auto crec = std::make_shared<Rec>();
  auto cclient = liveClient(crec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})));
  Value cres = direct(cclient);
  ASSERT_TRUE(okOf(cres), "malformed control: direct failed: " + errOf(cres));
  ASSERT_EQ(crec->api, 1, "malformed control: exactly one call");
  ASSERT_EQ(crec->auth(0), expectAuth(cclient.get(), "CHAINKEY"), "malformed control: credential");
}

static void t_selected_kinds_in_vocabulary() {
  std::vector<std::shared_ptr<void>> defs = featurePlugins("secrets");
  std::printf("secrets: %zu plugin definition(s) selected by the model\n", defs.size());
  const std::vector<std::string>& shipped = sekreto::KINDS().plugin;
  for (const auto& erased : defs) {
    auto def = std::static_pointer_cast<plugin::Definition>(erased);
    ASSERT_NOTNULL(def, "vocabulary: a definition is not null");
    if (!def) continue;
    ASSERT_TRUE(shipped.end() != std::find(shipped.begin(), shipped.end(), def->name),
                "vocabulary: " + def->name + " is a kind sekreto ships");
    // A chain naming a selected kind CONSTRUCTS (nothing is contacted until
    // the first lookup), which is the whole point of passing it in.
    if ("hashicorp" == def->name) {
      auto rec = std::make_shared<Rec>();
      auto client = liveClient(rec, secretsOpts(vlist({
        vmap({{"kind", Value(std::string("hashicorp"))},
              {"addr", Value(std::string("https://127.0.0.1:9"))},
              {"token", Value(std::string("t"))}})})));
      auto f = SecretsFeature::of(client.get());
      ASSERT_TRUE(f && f->initError().empty(),
                  "vocabulary: a selected kind builds: " + (f ? f->initError() : std::string("(no feature)")));
      // Its lookup fails to CONNECT (nothing listens on 127.0.0.1:9), and
      // that ERROR must refuse the request: the vault kind is fail-closed
      // through the same gate as everything else.
      Value res = direct(client);
      ASSERT_FALSE(okOf(res), "vocabulary: an unreachable vault refuses the request");
      ASSERT_TRUE(contains(errOf(res), "sekreto"), "vocabulary: with sekreto's message: " + errOf(res));
      ASSERT_EQ(rec->api, 0, "vocabulary: nothing sent past an unreachable vault");
    }
  }
  ASSERT_TRUE(true, "vocabulary: read");
}

static void t_raw_paths_get_chain_credential() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINKEY")})));
  Value d = direct(client);
  ASSERT_TRUE(okOf(d), "raw: direct failed: " + errOf(d));
  Value g = client->graphql("query { thing { id } }");
  ASSERT_TRUE(okOf(g), "raw: graphql failed: " + errOf(g));
  ASSERT_EQ(rec->api, 2, "raw: two calls");
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "CHAINKEY"), "raw: direct carries the chain credential");
  ASSERT_EQ(rec->auth(1), expectAuth(client.get(), "CHAINKEY"), "raw: graphql carries the chain credential");
}

// ---- the exchange ------------------------------------------------------------------

static Value exchangeOn(const Value& more = Value::undef()) {
  Value x = vmap({{"active", Value(true)}});
  if (more.is_map()) for (const auto& kv : *more.as_map()) map_put(x, kv.first, kv.second);
  return x;
}

static void t_exchange_buys_and_carries() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "exchange: direct failed: " + errOf(res));
  ASSERT_EQ(rec->token, 1, "exchange: one token purchase");
  ASSERT_EQ(rec->api, 1, "exchange: one API call");
  ASSERT_TRUE(contains(rec->url(0), "http://api.test/auth/token"), "exchange: endpoint relative to base: " + rec->url(0));
  ASSERT_TRUE(contains(rec->body(0), "\"refresh_token\":\"REFRESH1\""), "exchange: marshalled body: " + rec->body(0));
  ASSERT_EQ(rec->auth(1), expectAuth(client.get(), "ACCESS01"), "exchange: the ACCESS token is on the wire");
  ASSERT_FALSE(contains(rec->auth(1), "REFRESH1"), "exchange: the refresh token never is");
}

static void t_exchange_explicit_refresh_wins() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "CHAINREFRESH")}),
    vmap({{"exchange", exchangeOn(vmap({{"refresh", Value(std::string("R2"))}}))}})));
  direct(client);
  ASSERT_EQ(rec->token, 1, "explicit refresh: one purchase");
  ASSERT_TRUE(contains(rec->body(0), "\"R2\""), "explicit refresh: exchange.refresh seats first: " + rec->body(0));
}

static void t_exchange_one_purchase_many_requests() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})));
  direct(client); direct(client); direct(client);
  ASSERT_EQ(rec->token, 1, "many: one purchase serves many requests");
  ASSERT_EQ(rec->api, 3, "many: three API calls");
}

static void t_exchange_401_rebuys_and_retries() {
  auto rec = std::make_shared<Rec>();
  rec->script = {401, 200};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "401: the retried request succeeded: " + errOf(res));
  ASSERT_EQ(rec->token, 2, "401: bought again");
  ASSERT_EQ(rec->api, 2, "401: retried once");
  // calls: token, api(401), token, api(200)
  ASSERT_EQ(rec->auth(1), expectAuth(client.get(), "ACCESS01"), "401: first attempt with the first token");
  ASSERT_EQ(rec->auth(3), expectAuth(client.get(), "ACCESS02"), "401: the retry carries the NEW token");
}

static void t_exchange_retry_once_not_loop() {
  auto rec = std::make_shared<Rec>();
  rec->script = {401, 401, 401};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})));
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "loop: a second 401 is returned, not spun on");
  ASSERT_EQ(rec->api, 2, "loop: exactly one retry (retries: 1)");
  ASSERT_EQ(rec->token, 2, "loop: exactly two purchases");
}

static void t_exchange_other_status_not_expiry() {
  auto rec = std::make_shared<Rec>();
  rec->script = {403};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})));
  direct(client);
  ASSERT_EQ(rec->api, 1, "403: not an expiry, no retry");
  ASSERT_EQ(rec->token, 1, "403: no second purchase");
}

static void t_exchange_statuses_configurable() {
  auto rec = std::make_shared<Rec>();
  rec->script = {403, 200};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
    vmap({{"exchange", exchangeOn(vmap({{"statuses", vlist({Value(403)})}}))}})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "statuses: retried on the configured status: " + errOf(res));
  ASSERT_EQ(rec->api, 2, "statuses: one retry");
  ASSERT_EQ(rec->token, 2, "statuses: two purchases");
}

static void t_exchange_fields_configurable() {
  auto rec = std::make_shared<Rec>();
  rec->tokenfield = "at";
  rec->tokenpath = "/oauth/token";
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
    vmap({{"exchange", exchangeOn(vmap({
      {"path", Value(std::string("oauth/token"))},
      {"request", Value(std::string("rt"))},
      {"response", Value(std::string("at"))}}))}})));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "fields: direct failed: " + errOf(res));
  ASSERT_TRUE(contains(rec->url(0), "/oauth/token"), "fields: configured path");
  ASSERT_TRUE(contains(rec->body(0), "\"rt\":\"REFRESH1\""), "fields: configured request field: " + rec->body(0));
  ASSERT_EQ(rec->auth(1), expectAuth(client.get(), "ACCESS01"), "fields: configured response field read");
}

static void t_exchange_explicit_apikey_spent_first() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})),
                           vmap({{"apikey", Value(std::string("OLDACCESS"))}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "spent first: direct failed: " + errOf(res));
  ASSERT_EQ(rec->token, 0, "spent first: a held access token is spent before any purchase");
  ASSERT_EQ(rec->auth(0), expectAuth(client.get(), "OLDACCESS"), "spent first: the option is the starting token");
}

static void t_exchange_expired_apikey_falls_through() {
  auto rec = std::make_shared<Rec>();
  rec->script = {401, 200};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})),
                           vmap({{"apikey", Value(std::string("OLDACCESS"))}}));
  Value res = direct(client);
  ASSERT_TRUE(okOf(res), "expired: the retry succeeded: " + errOf(res));
  ASSERT_EQ(rec->token, 1, "expired: one purchase after the refusal");
  ASSERT_EQ(rec->api, 2, "expired: one retry");
  ASSERT_EQ(rec->auth(2), expectAuth(client.get(), "ACCESS01"), "expired: the retry carries the bought token");
}

static void t_exchange_no_refresh_is_error() {
  auto rec = std::make_shared<Rec>();
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("OTHER", "X")}),
                                            vmap({{"exchange", exchangeOn()}})));
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "no refresh: refused");
  ASSERT_TRUE(contains(errOf(res), "secrets: no refresh token"), "no refresh: says so: " + errOf(res));
  ASSERT_EQ(rec->api, 0, "no refresh: nothing sent");
  ASSERT_EQ(rec->token, 0, "no refresh: nothing bought");
}

static void t_exchange_failing_endpoint_surfaces_refusal() {
  auto rec = std::make_shared<Rec>();
  rec->script = {401};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})),
                           vmap({{"apikey", Value(std::string("OLDACCESS"))}}));
  rec->tokenstatus = 500;
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "failing endpoint: the API's refusal is answered");
  ASSERT_EQ(rec->api, 1, "failing endpoint: no retry without a token");
  ASSERT_EQ(rec->token, 1, "failing endpoint: one attempted purchase");
}

static void t_exchange_auth_null_suppresses() {
  auto rec = std::make_shared<Rec>();
  rec->script = {401};
  auto client = liveClient(rec, secretsOpts(vlist({memoryProvider("APIKEY", "REFRESH1")}),
                                            vmap({{"exchange", exchangeOn()}})),
                           vmap({{"auth", Value(nullptr)}}));
  Value res = direct(client);
  ASSERT_FALSE(okOf(res), "auth null exchange: the 401 comes back");
  ASSERT_EQ(rec->api, 1, "auth null exchange: no retry for a deliberately unauthenticated request");
  ASSERT_FALSE(rec->hasAuth(rec->calls.size() - 1), "auth null exchange: no header");
}

// Test mode buys nothing: through the harness, whose client is testSDK().
static void t_exchange_test_mode_buys_nothing() {
  auto rec = std::make_shared<FhRecorder>();
  auto server = [rec](CtxPtr ctx, const std::string& url, const Value& fd) {
    return rec->fetch(ctx, url, fd);
  };
  auto h = fhMake(server, {fhF(std::make_shared<SecretsFeature>(),
                              fhMap({{"providers", vlist({memoryProvider("APIKEY", "REFRESH1")})},
                                     {"exchange", exchangeOn()}}))});
  FhOpResult r = h->op(fhOp("load"));
  ASSERT_TRUE(r.ok, "test mode: op failed: " + (r.err ? r.err->msg : std::string("")));
  ASSERT_EQ(rec->calls.size(), (size_t)1, "test mode: exactly one call, and it is the API call");
  Value auth = getp(rec->headers(0), "authorization");
  ASSERT_EQ(as_str(auth), expectAuth(h->client.get(), "test-access_token"),
            "test mode: the deterministic fake token");
}

// The entity pipeline through the harness carries the chain credential too
// (the happy path of t_provider_error_fails_entity_op).
static void t_entity_op_gets_chain_credential() {
  auto rec = std::make_shared<FhRecorder>();
  auto server = [rec](CtxPtr ctx, const std::string& url, const Value& fd) {
    return rec->fetch(ctx, url, fd);
  };
  auto h = fhMake(server, {fhF(std::make_shared<SecretsFeature>(),
                              fhMap({{"providers", vlist({memoryProvider("APIKEY", "CHAINKEY")})}}))});
  FhOpResult r = h->op(fhOp("list"));
  ASSERT_TRUE(r.ok, "entity: op failed: " + (r.err ? r.err->msg : std::string("")));
  ASSERT_EQ(rec->calls.size(), (size_t)1, "entity: one call");
  ASSERT_EQ(as_str(getp(rec->headers(0), "authorization")), expectAuth(h->client.get(), "CHAINKEY"),
            "entity: the chain credential on the entity path");
}

int main() {
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
  RUN(t_chain_is_live);
  RUN(t_unknown_kind_refused);
  RUN(t_malformed_entry_never_dropped);
  RUN(t_selected_kinds_in_vocabulary);
  RUN(t_raw_paths_get_chain_credential);
  RUN(t_entity_op_gets_chain_credential);
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
  RUN(t_exchange_test_mode_buys_nothing);

  std::printf("secrets: ran %d case(s)\n", CASES);
  return sdktest::summary("secrets_test");
}
