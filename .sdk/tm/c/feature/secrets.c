// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The c port of
// tm/ts/src/feature/secrets/SecretsFeature.ts, following the GO port's
// structure (tm/go/feature/secrets_feature.go) - same contract, c idiom.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
// vault never degrades into an unauthenticated request.
//
// WHERE RESOLUTION HAPPENS, and why it is not the PreSpec hook. c's hook
// slot is `void (*hook)(Feature*, const char*, Context*)` (core/sdk.h): a
// hook cannot fail an operation the way ts's awaited rejection can - and
// sdk_direct / sdk_graphql run no feature hooks at all (Main.fragment.c's
// sdk_raw_request calls utility_fetch directly). So, exactly as in go and
// rust, resolution happens at the TRANSPORT SEAM: `Utility.fetcher`, the
// one place every wire path crosses (entity ops through make_request,
// the raw paths through sdk_raw_request, both reading the client's one
// Utility). The wrapper refuses to send while the last resolution stands
// failed, which is fail-closed for the entity pipeline and the raw paths
// alike, with one implementation.
//
// WHERE THE CREDENTIAL LIVES, and why it is not the options map. The ts
// reference writes `options.apikey`; this port does NOT. prepare_auth
// builds the header from the client's options on every request, and this
// feature rewrites that header at the seam from a value it holds itself -
// same construction, same suppression rules - so `sdk_options_map` stays
// exactly what the caller passed, and the raw paths and the entity path
// cannot disagree about it. (go's structural rule, kept here for the same
// reason even though c is single threaded.)
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when
// a response status in `exchange.statuses` (401) says it is spent the
// wrapper buys another and retries the same request once. Test mode buys
// nothing and answers with a deterministic fake token.
//
// THE c-SPECIFIC SEAMS, stated because the parity table cannot check them:
//
//   * A live provider object cannot travel in the options: voxgig_value is
//     a closed union (UNDEF|NULL|BOOL|INT|DOUBLE|STRING|LIST|MAP|FUNC|
//     SENTINEL), so go's `providers: [&customProvider{}]` has no c spelling.
//     The answer is the `custom` pseudo-kind: a providers entry that is a
//     FUNC, or a map `{ kind: "custom", lookup: <FUNC>, name?: "..." }`,
//     bridged by a sek_provider whose lookup calls the FUNC through
//     call_vfn - the same shape options.system.fetch and the retry
//     feature's injected sleep already use. The FUNC is handed the secret
//     NAME and answers a STRING (a hit), Noval/Null (a MISS - the chain
//     continues) or a map `{ "__err__": "..." }` (an ERROR - the operation
//     fails). Conflating the last two is the failure this library exists
//     to prevent.
//
//   * The c core ships no HTTP client (utility/fetcher.c). The exchange
//     therefore uses options.system.fetch when supplied - the seam every
//     live c request already lives under - and otherwise
//     `secrets_rawfetch`, which lives in the GENERATED feature/secrets/
//     kinds.c: a libcurl round-trip when a plugin group is active, a
//     transport error that says so when none is (see Config_c; the
//     generated kinds.mk beside it is what links libcurl on the same
//     condition).
//
//   * sek_new is documented NOT REENTRANT (a file-scope slot for the
//     duration of the call). It runs once, in the client constructor,
//     which is single threaded by core/context.c's own declaration; the
//     same declaration is what lets this port drop go's mutex / in-flight
//     promise apparatus. The pool a chain is built from is never freed:
//     the c SDK is never-free (core/sdk.h "MEMORY MODEL"), and plugin's
//     C port holds its declarations in a process arena regardless.

#include "sdk.h"

#include "secrets.h"

#include "sekreto.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The exchange transport of last resort, defined in the GENERATED
// feature/secrets/kinds.c (Config_c) - libcurl when a plugin group is
// active, a "no transport" error otherwise. Prototyped here rather than in
// sdk.h because core/ must not know a gated feature's internals.
voxgig_value* secrets_rawfetch(Context* ctx, const char* url,
                               voxgig_value* fetchdef, PNError** err);

typedef struct {
  const char* path;
  const char* method;
  const char* request;
  const char* response;
  int64_t* statuses;
  size_t nstatuses;
  int64_t retries;
} SecretsExchange;

typedef struct {
  int64_t resolves; // chain resolutions that completed (hit or miss)
  int64_t buys;     // token purchases (test mode included)
  int64_t refused;  // requests the fail-closed gate refused to send
} SecretsTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  UnivecSDK* client;
  // The LIVE options map (root ctx options): read for `apikey` and `auth`,
  // never written.
  voxgig_value* liveopts;

  const char* secretname;
  bool cache;

  sek_pool* pool;
  sek_sekreto* sek;

  // sekreto's own message when construction failed; the gate reads it.
  char* initerr;

  // The RESOLVED credential (the access token when exchanging), held here
  // and injected at the seam - never written into the options map.
  char* cred;
  // A cached resolution stands (cache: true only); a FAILURE never sets it,
  // so the next request asks the chain again.
  bool resolved;

  SecretsExchange* exchange;
  char* refresh;

  SecretsTrack track;
} SecretsFeature;

typedef struct {
  Fetcher* inner;
  SecretsFeature* f;
} SecretsState;

// ---- the custom-provider bridge --------------------------------------------

typedef struct {
  voxgig_value* fn;
  sek_pool* pool;
} CustomData;

static sek_err custom_lookup(sek_provider* self, const char* name, char** out) {
  CustomData* d = (CustomData*)self->data;
  voxgig_value* got = call_vfn(d->fn, v_str(name));
  *out = NULL;
  if (voxgig_is_string(got)) {
    *out = sek_strdup(d->pool, voxgig_as_string(got));
    return NULL;
  }
  if (voxgig_is_map(got)) {
    const char* emsg = get_str(got, "__err__");
    if (NULL != emsg) return sek_strdup(d->pool, emsg);
  }
  // Noval, Null, or anything that is not a value: a MISS.
  return NULL;
}

static const char* custom_describe(sek_provider* self) {
  (void)self;
  return "custom";
}

static sek_provider* custom_provider(sek_pool* pool, voxgig_value* fn) {
  CustomData* d = (CustomData*)sek_alloc(pool, sizeof(CustomData));
  d->fn = v_share(fn);
  d->pool = pool;
  return sek_provider_new(pool, custom_lookup, custom_describe, d);
}

// ---- options map -> sek_spec ------------------------------------------------

// The spec's own key names paired with where each lands in a sek_spec - the
// same table upstream's providers.c keeps (specof), because the two
// directions must not drift. Strings only, as upstream reads them; `values`,
// `kv` and `auth` are not strings and are handled below.
typedef struct {
  const char* key;
  size_t at;
} SpecField;

#define SF(name, member) {name, offsetof(sek_spec, member)}
#define SAF(name, member) {name, offsetof(sek_authspec, member)}

static const SpecField SPECFIELDS[] = {
  SF("kind", kind), SF("name", name), SF("prefix", prefix), SF("file", file),
  SF("dir", dir), SF("addr", addr), SF("token", token), SF("mount", mount),
  SF("vaultnamespace", vaultnamespace), SF("command", command),
  SF("profile", profile), SF("backend", backend), SF("reason", reason),
  SF("namespace", namespace_), SF("home", home), SF("region", region),
  SF("keyid", keyid), SF("secret", secret), SF("session", session),
  SF("project", project), SF("vault", vault), SF("tenant", tenant),
  SF("clientid", clientid), SF("clientsecret", clientsecret),
  SF("loginaddr", loginaddr), SF("imdsaddr", imdsaddr),
  SF("metadataaddr", metadataaddr), SF("apiversion", apiversion),
  SF("config", config), SF("environment", environment), SF("path", path),
};

static const SpecField AUTHFIELDS[] = {
  SAF("method", method), SAF("mount", mount), SAF("role", role), SAF("jwt", jwt),
  SAF("jwtfile", jwtfile), SAF("roleid", roleid), SAF("secretid", secretid),
};

// A providers entry that is a map, as a spec. Answers false, with the
// refusal in *why, when the map says `custom` but carries no callable.
static bool spec_of_map(sek_pool* pool, voxgig_value* m, sek_spec* spec, const char** why) {
  *spec = sek_spec_new(NULL);
  *why = NULL;

  const char* kind = get_str(m, "kind");
  if (NULL != kind && 0 == strcmp(kind, "custom")) {
    voxgig_value* lookup = getp(m, "lookup");
    if (!voxgig_is_func(lookup)) {
      *why = "a `custom` provider needs a `lookup` callable";
      return false;
    }
    spec->provider = custom_provider(pool, lookup);
    const char* name = get_str(m, "name");
    if (NULL != name && '\0' != name[0]) spec->name = sek_own(pool, name);
    return true;
  }

  for (size_t i = 0; i < sizeof(SPECFIELDS) / sizeof(SPECFIELDS[0]); i++) {
    const char* held = get_str(m, SPECFIELDS[i].key);
    if (NULL != held) {
      *(const char**)((char*)spec + SPECFIELDS[i].at) = sek_own(pool, held);
    }
  }

  voxgig_value* values = getp(m, "values");
  if (voxgig_is_map(values)) {
    voxgig_map* vm = voxgig_as_map(values);
    spec->values = sek_map_new(pool);
    for (size_t i = 0; i < vm->len; i++) {
      voxgig_value* held = vm->entries[i].value;
      char* text = voxgig_is_string(held) ? strdup(voxgig_as_string(held))
                                          : voxgig_stringify(held, 0);
      sek_map_set(spec->values, vm->entries[i].key, sek_own(pool, text));
      free(text);
    }
  }

  voxgig_value* kv = getp(m, "kv");
  if (voxgig_is_number(kv)) {
    spec->kv = (int)to_int(kv);
    spec->haskv = 1;
  }

  voxgig_value* auth = getp(m, "auth");
  if (voxgig_is_map(auth)) {
    sek_authspec* use = (sek_authspec*)sek_alloc(pool, sizeof(sek_authspec));
    for (size_t i = 0; i < sizeof(AUTHFIELDS) / sizeof(AUTHFIELDS[0]); i++) {
      const char* held = get_str(auth, AUTHFIELDS[i].key);
      if (NULL != held) {
        *(const char**)((char*)use + AUTHFIELDS[i].at) = sek_own(pool, held);
      }
    }
    spec->auth = use;
  }

  return true;
}

// ---- credential injection ---------------------------------------------------

// Write the resolved credential into THIS request's authorization header,
// the way prepare_auth builds it (same options auth.prefix, same
// suppression rule), so the two cannot drift.
//
// `auth: null` is the documented way to send NO credential, and
// prepare_auth honours it by removing the header; so does this, and it
// never writes one - which is what keeps the exchange from transmitting
// exactly the credential the caller suppressed on a retry. An EMPTY
// credential leaves prepare_auth's header alone: nothing was resolved, so
// there is nothing to inject and nothing to retract that prepare_auth did
// not already decide.
static void secrets_reauth(SecretsFeature* f, voxgig_value* fetchdef) {
  voxgig_value* headers = getp(fetchdef, "headers");
  if (!voxgig_is_map(headers)) return;

  voxgig_value* auth = getp(f->liveopts, "auth");
  if (v_is_noval(auth) || v_is_null(auth)) {
    voxgig_value* k = voxgig_new_string("authorization");
    voxgig_delprop(headers, k);
    voxgig_release(k);
    return;
  }

  if (NULL == f->cred || '\0' == f->cred[0]) return;

  const char* prefix = get_str(auth, "prefix");
  if (NULL == prefix || '\0' == prefix[0]) {
    setp(headers, "authorization", v_str(f->cred));
  } else {
    size_t n = strlen(prefix) + 1 + strlen(f->cred) + 1;
    char* buf = (char*)malloc(n);
    snprintf(buf, n, "%s %s", prefix, f->cred);
    setp(headers, "authorization", v_str(buf));
    free(buf);
  }
}

static void secrets_setcred(SecretsFeature* f, const char* value) {
  free(f->cred);
  f->cred = strdup(NULL == value ? "" : value);
}

// ---- the exchange -----------------------------------------------------------

// Buy an access token with the refresh token. Answers sekreto-style: a
// pool-owned message, or NULL for success with the token in f->cred.
static const char* secrets_buy(SecretsFeature* f, Context* ctx) {
  SecretsExchange* x = f->exchange;

  // TEST MODE BUYS NOTHING. The test feature replaces the transport so no
  // request leaves the process; an exchange here would be the one HTTP
  // call it could not stop, and it would need a live token endpoint for a
  // suite whose whole point is not needing one. A deterministic,
  // obviously-fake token instead - the same answer make_options gives a
  // required server variable, for the same reason.
  if (0 != strcmp(f->client->mode, "live")) {
    size_t n = 5 + strlen(x->response) + 1;
    char* fake = (char*)malloc(n);
    snprintf(fake, n, "test-%s", x->response);
    secrets_setcred(f, fake);
    free(fake);
    f->track.buys++;
    return NULL;
  }

  if (NULL == f->refresh || '\0' == f->refresh[0]) {
    return sek_fmt(f->pool,
      "secrets: no refresh token: the provider chain has no '%s', and "
      "feature.secrets.exchange.refresh is unset", f->secretname);
  }

  voxgig_value* options = sdk_options_map(f->client);

  // The token endpoint is RELATIVE to the base, which already carries
  // whatever account or tenant segment the server URL declares.
  const char* base = get_str(options, "base");
  base = base ? base : "";
  size_t blen = strlen(base);
  while (0 < blen && '/' == base[blen - 1]) blen--;
  const char* path = x->path;
  while ('/' == path[0]) path++;
  char* url = sek_fmt(f->pool, "%.*s/%s", (int)blen, base, path);

  // The body is MARSHALLED, never concatenated: a refresh token (or a
  // configured request-field name) carrying a quote, backslash or newline
  // must arrive as that literal value, not as malformed JSON. sekreto's
  // own JSON writer does it.
  sek_json* body = sek_json_obj(f->pool);
  sek_json_set(f->pool, body, x->request, sek_json_str(f->pool, f->refresh));
  char* bodytext = sek_json_stringify(f->pool, body);

  voxgig_value* fetchdef = cmap(3,
    "method", v_str(x->method),
    "headers", cmap(1, "content-type", v_str("application/json")),
    "body", v_str(bodytext));

  // Deliberately NOT the SDK transport. The transport is what this feature
  // wraps, and sending the token request back through it would recurse on
  // the first expiry - and would route the exchange through the test mock,
  // which knows nothing about it. options.system.fetch when the caller
  // supplied one (the seam every live c request already uses), else the
  // bundled transport of last resort from the generated kinds.c.
  voxgig_value* sys_fetch = getpath2(options, "system", "fetch");
  voxgig_value* res;
  if (voxgig_is_func(sys_fetch)) {
    res = call_vfn(sys_fetch, clist(2, v_str(url), v_share(fetchdef)));
    const char* emsg = get_str(res, "__err__");
    if (NULL != emsg) return sek_strdup(f->pool, emsg);
  } else {
    PNError* ferr = NULL;
    res = secrets_rawfetch(ctx, url, fetchdef, &ferr);
    if (NULL != ferr) return sek_strdup(f->pool, ferr->msg ? ferr->msg : "secrets: transport failed");
  }

  int64_t status = to_int(getp(res, "status"));
  if (200 > status || 300 <= status) {
    return sek_fmt(f->pool, "secrets: token exchange failed: %lld from %s",
                   (long long)status, url);
  }

  voxgig_value* jf = getp(res, "json");
  voxgig_value* parsed;
  if (voxgig_is_func(jf)) {
    parsed = call_json(jf);
  } else {
    voxgig_value* raw = getp(res, "body");
    parsed = voxgig_is_string(raw) ? json_parse(voxgig_as_string(raw)) : raw;
  }

  const char* token = get_str(parsed, x->response);
  if (NULL == token || '\0' == token[0]) {
    return sek_fmt(f->pool, "secrets: token exchange returned no '%s' field from %s",
                   x->response, url);
  }

  secrets_setcred(f, token);
  f->track.buys++;
  return NULL;
}

static bool secrets_spent(SecretsFeature* f, voxgig_value* res) {
  int64_t status;
  if (!fres_status(res, &status)) return false;
  for (size_t i = 0; i < f->exchange->nstatuses; i++) {
    if (f->exchange->statuses[i] == status) return true;
  }
  return false;
}

// ---- resolution -------------------------------------------------------------

// One resolution. A settled SUCCESS is kept only when caching is on
// (`cache: false` means every request asks the chain again, and sekreto's
// own cache is off with it); a FAILURE is never kept, so a transient vault
// outage never poisons the client - the next request asks again. Answers
// the provider's own message, or NULL.
static const char* secrets_resolve(SecretsFeature* f, Context* ctx) {
  if (NULL != f->initerr) return f->initerr;
  if (f->cache && f->resolved) return NULL;
  if (NULL == f->sek) return NULL;

  char* found = NULL;
  sek_err err = sek_try(f->sek, f->secretname, &found);
  if (NULL != err) {
    // A provider ERROR fails the op (via the transport gate); only a MISS
    // falls through.
    return err;
  }
  f->track.resolves++;

  if (NULL == f->exchange) {
    // A hit is the credential. An UNCACHED miss after an earlier hit is a
    // revocation: the chain now says no provider has the secret, so the
    // resolved value must not keep going out on the wire. (An explicit
    // apikey OPTION is never lost here - it seats FIRST in the chain as a
    // memory provider, so the chain HITS while one is set.)
    secrets_setcred(f, found);
    f->resolved = true;
    return NULL;
  }

  // Exchanging: what the chain resolved is the REFRESH token, kept for
  // every later purchase. A miss is not fatal here - an explicit `apikey`
  // may already hold a usable access token, and the API is what gets to
  // say whether it does.
  free(f->refresh);
  f->refresh = strdup(found ? found : "");

  if ('\0' == f->cred[0]) {
    // A starting access token supplied as the OPTION: read from the frozen
    // options map (no feature ever writes it).
    const char* held = get_str(f->liveopts, "apikey");
    if (NULL != held && '\0' != held[0]) secrets_setcred(f, held);
  }
  if ('\0' != f->cred[0]) {
    // Spend it: if it is stale the API answers with an expiry status and
    // the wrapper buys another, which is the same path expiry takes anyway.
    f->resolved = true;
    return NULL;
  }

  const char* berr = secrets_buy(f, ctx);
  if (NULL != berr) return berr;
  f->resolved = true;
  return NULL;
}

// ---- the transport wrapper --------------------------------------------------

static voxgig_value* secrets_fetch(Fetcher* self, Context* ctx, const char* url,
                                   voxgig_value* fetchdef, PNError** err) {
  SecretsState* st = (SecretsState*)self->state;
  SecretsFeature* f = st->f;
  *err = NULL;

  // FAIL-CLOSED, at the ONE seam every wire path crosses. Entity ops,
  // sdk_direct, sdk_graphql and the exchange retries all come through
  // here, so resolving HERE is what gives the raw paths - which run no
  // feature hooks at all - the same credential the entity pipeline gets.
  // A construction failure (initerr) or a provider ERROR refuses the
  // request with sekreto's own message - never an unauthenticated send.
  if (NULL != f->initerr) {
    f->track.refused++;
    *err = context_make_error(ctx, "secrets_init", f->initerr);
    return NULL;
  }
  const char* rerr = secrets_resolve(f, ctx);
  if (NULL != rerr) {
    f->track.refused++;
    *err = context_make_error(ctx, "secrets_resolve", rerr);
    return NULL;
  }

  // Inject the resolved credential into THIS request's header (the header
  // was built by prepare_auth from the options apikey; the chain-resolved
  // value lives in feature state instead).
  secrets_reauth(f, fetchdef);

  if (NULL == f->exchange) {
    return st->inner->fn(st->inner, ctx, url, fetchdef, err);
  }

  // `auth: null` is a deliberately unauthenticated request: a refusal of it
  // is not an expired token and cannot be fixed by buying one.
  voxgig_value* auth = getp(f->liveopts, "auth");
  if (v_is_noval(auth) || v_is_null(auth)) {
    return st->inner->fn(st->inner, ctx, url, fetchdef, err);
  }

  int64_t max = f->exchange->retries;
  int64_t attempt = 0;
  for (;;) {
    // The credential THIS attempt goes out with, captured before it leaves:
    // it is what tells a stale refusal apart from a fresh one.
    char* used = strdup(f->cred);

    PNError* e = NULL;
    voxgig_value* out = st->inner->fn(st->inner, ctx, url, fetchdef, &e);

    if (NULL != e || attempt >= max || !secrets_spent(f, out)) {
      free(used);
      *err = e;
      return out;
    }

    // A token bought since this attempt left (single threaded, so only by
    // a nested request from a callback) is spent before another is bought:
    // a second exchange for a token that is already fresh is wasted, and
    // on a provider that invalidates the previous credential on issuance
    // it breaks this request's own retry.
    if ('\0' == f->cred[0] || 0 == strcmp(f->cred, used)) {
      const char* berr = secrets_buy(f, ctx);
      if (NULL != berr) {
        // The purchase failed: answer with the API's own refusal rather
        // than this one. The caller asked for data, and the refusal is
        // the more useful of the two - the exchange error is a symptom.
        free(used);
        return out;
      }
    }
    free(used);

    secrets_reauth(f, fetchdef);
    attempt++;
  }
}

// ---- the feature ------------------------------------------------------------

static const char* secrets_name(Feature* f) { return ((SecretsFeature*)f)->name; }
static bool secrets_active(Feature* f) { return ((SecretsFeature*)f)->active; }
static voxgig_value* secrets_add_options(Feature* f) { return ((SecretsFeature*)f)->add_opts; }

static void secrets_fail(SecretsFeature* f, const char* msg) {
  // The FIRST failure stands: it names the entry the caller has to fix.
  if (NULL == f->initerr) f->initerr = strdup(msg);
}

// Init is sync by feature contract: build the chain, never look anything up
// here.
static void secrets_init(Feature* fb, Context* ctx, voxgig_value* options) {
  SecretsFeature* f = (SecretsFeature*)fb;
  f->options = options;
  f->active = fopt_bool(options, "active", false);
  if (!f->active) return;

  f->client = ctx->client;
  f->liveopts = ctx->options;

  // WRAP FIRST. The fail-closed gate needs the seam whatever happens
  // below - a chain that fails to build must still refuse to send - so the
  // wrapper is installed before anything here can fail, and the exchange
  // (when on) additionally needs to SEE responses: expiry is only ever
  // discovered from one, and this is the one place a response can be seen
  // and the request tried again.
  Utility* util = context_util(ctx);
  SecretsState* st = (SecretsState*)calloc(1, sizeof(SecretsState));
  st->inner = util->fetcher;
  st->f = f;
  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = secrets_fetch;
  wrapped->state = st;
  util->fetcher = wrapped;

  f->secretname = fopt_str(options, "name", "apikey");
  f->cache = fopt_bool(options, "cache", true);
  f->pool = sek_pool_new();

  // Exchange config, normalised once. NULL when off, so every later
  // decision is a NULL check.
  voxgig_value* xopts = fopt_map(options, "exchange");
  if (fopt_bool(xopts, "active", false)) {
    SecretsExchange* x = (SecretsExchange*)calloc(1, sizeof(SecretsExchange));
    x->path = fopt_str(xopts, "path", "auth/token");
    x->method = fopt_str(xopts, "method", "POST");
    x->request = fopt_str(xopts, "request", "refresh_token");
    x->response = fopt_str(xopts, "response", "access_token");
    x->retries = fopt_int(xopts, "retries", 1);
    voxgig_value* sl = fopt_list(xopts, "statuses");
    if (voxgig_is_list(sl) && 0 < voxgig_as_list(sl)->len) {
      voxgig_list* l = voxgig_as_list(sl);
      x->statuses = (int64_t*)calloc(l->len, sizeof(int64_t));
      for (size_t i = 0; i < l->len; i++) {
        if (voxgig_is_number(l->items[i])) x->statuses[x->nstatuses++] = to_int(l->items[i]);
      }
    }
    if (0 == x->nstatuses) {
      x->statuses = (int64_t*)calloc(1, sizeof(int64_t));
      x->statuses[0] = 401;
      x->nstatuses = 1;
    }
    f->exchange = x;
  }

  // The explicit credential, when set, is the first store in the chain.
  //
  // WHICH option that is depends on the exchange. Without one, the secret
  // being resolved IS the credential the transport sends, so `apikey` is
  // it. With one, the secret is a REFRESH token and `apikey` means the
  // opposite thing - an access token the caller already holds - so the
  // explicit seat belongs to `exchange.refresh`, and apikey is left alone
  // to serve as the starting access token (see secrets_resolve).
  //
  // Read DIRECTLY, not through fopt_str, which answers its default for an
  // empty string: an explicitly EMPTY apikey means "defer to the chain".
  const char* explicit = NULL;
  if (NULL == f->exchange) {
    explicit = get_str(f->liveopts, "apikey");
  } else {
    explicit = get_str(xopts, "refresh");
  }

  size_t cap = 4;
  size_t count = 0;
  sek_spec* specs = (sek_spec*)calloc(cap, sizeof(sek_spec));
#define SPEC_PUSH(s) do { \
    if (count == cap) { cap *= 2; specs = (sek_spec*)realloc(specs, cap * sizeof(sek_spec)); } \
    specs[count++] = (s); \
  } while (0)

  if (NULL != explicit && '\0' != explicit[0]) {
    char* key = NULL;
    sek_err kerr = sek_envkey(f->pool, f->secretname, "", &key);
    if (NULL != kerr) {
      secrets_fail(f, kerr);
    } else {
      sek_spec seat = sek_spec_new("memory");
      seat.name = "options";
      seat.values = sek_map_new(f->pool);
      sek_map_set(seat.values, key, sek_own(f->pool, explicit));
      SPEC_PUSH(seat);
    }
  }

  voxgig_value* providers = fopt_list(options, "providers");
  if (voxgig_is_list(providers)) {
    voxgig_list* pl = voxgig_as_list(providers);
    for (size_t i = 0; i < pl->len; i++) {
      voxgig_value* p = pl->items[i];
      if (voxgig_is_func(p)) {
        // A provider already built (as built as c can spell it): joins
        // the chain as it is.
        sek_spec live = sek_spec_new(NULL);
        live.provider = custom_provider(f->pool, p);
        SPEC_PUSH(live);
      } else if (voxgig_is_map(p)) {
        sek_spec spec;
        const char* why = NULL;
        if (spec_of_map(f->pool, p, &spec, &why)) {
          SPEC_PUSH(spec);
        } else {
          char* shown = voxgig_stringify(p, 0);
          secrets_fail(f, sek_fmt(f->pool,
            "sekreto: not a provider or a provider spec: %s (%s)", shown, why));
          free(shown);
        }
      } else {
        // FAIL CLOSED, never drop. An entry that is neither a callable nor
        // a spec map (a bare "hashicorp" where a spec was meant, a number,
        // a null) must not leave the chain quietly shorter than the
        // options say: sekreto's own wording lands in the init-failure
        // gate, which refuses to send. A loop that skipped the entry would
        // SHORTEN the chain instead of failing it - a misconfigured
        // providers list then sends ordinary unauthenticated requests, the
        // exact fail-open the gate exists to prevent.
        char* shown = voxgig_stringify(p, 0);
        secrets_fail(f, sek_fmt(f->pool,
          "sekreto: not a provider or a provider spec: %s", shown));
        free(shown);
      }
    }
  }
#undef SPEC_PUSH

  if (NULL == f->initerr) {
    // The plugin DEFINITIONS the model selected for this feature, from the
    // generated feature/secrets/kinds.c through core/config.c's accessor.
    // Upstream sekreto's contract since the registry was retired: a kind
    // not passed here is unknown to this Sekreto, so the model's choice of
    // plugin groups IS the SDK's provider vocabulary.
    size_t ndefs = 0;
    void** defs = feature_plugins("secrets", &ndefs);

    sek_options sopts;
    memset(&sopts, 0, sizeof(sopts));
    sopts.providers = specs;
    sopts.count = count;
    sopts.plugins = (Definition**)defs;
    sopts.plugincount = ndefs;
    sopts.nocache = f->cache ? 0 : 1;

    sek_sekreto* sek = NULL;
    sek_err serr = sek_new(f->pool, &sopts, &sek);
    if (NULL != serr) {
      // Init cannot fail the construction the way ts's throwing init does;
      // the transport gate refuses to send instead, which keeps a
      // misconfigured chain fail-closed rather than silently
      // unauthenticated.
      secrets_fail(f, serr);
    } else {
      f->sek = sek;
    }
  }
}

static void secrets_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* secrets_track(Feature* fb) {
  SecretsFeature* f = (SecretsFeature*)fb;
  return cmap(3,
    "resolves", v_num((double)f->track.resolves),
    "buys", v_num((double)f->track.buys),
    "refused", v_num((double)f->track.refused));
}

static const FeatureVT SECRETS_VT = {
  secrets_name, secrets_active, secrets_add_options, secrets_init, secrets_hook,
  secrets_track,
};

Feature* feature_secrets_new(void) {
  SecretsFeature* f = (SecretsFeature*)calloc(1, sizeof(SecretsFeature));
  f->base.vt = &SECRETS_VT;
  f->name = strdup("secrets");
  f->active = true; // overridden by init from options
  f->add_opts = NULL;
  f->options = voxgig_new_undef();
  f->cred = strdup("");
  f->refresh = strdup("");
  return (Feature*)f;
}

// ---- accessors (secrets.h) --------------------------------------------------

Feature* sdk_feature_secrets(UnivecSDK* sdk) {
  if (NULL == sdk) return NULL;
  for (size_t i = 0; i < sdk->features_len; i++) {
    Feature* f = sdk->features[i];
    if (0 == strcmp(f->vt->name(f), "secrets")) return f;
  }
  return NULL;
}

struct sek_sekreto* feature_secrets_sekreto(Feature* f) {
  return NULL == f ? NULL : ((SecretsFeature*)f)->sek;
}

const char* feature_secrets_credential(Feature* f) {
  return NULL == f ? "" : ((SecretsFeature*)f)->cred;
}

const char* feature_secrets_initerr(Feature* f) {
  return NULL == f ? NULL : ((SecretsFeature*)f)->initerr;
}
