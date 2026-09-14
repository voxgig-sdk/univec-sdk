// Univec SDK — secrets feature: secret access via a vendored
// @voxgig/sekreto provider chain, and the access-token exchange some APIs
// require on top of it. The cpp port of tm/ts/src/feature/secrets/
// SecretsFeature.ts, following the GO port's structure
// (tm/go/feature/secrets_feature.go) - same contract, C++ idiom.
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
// WHERE RESOLUTION HAPPENS, and why it is not the PreSpec hook. cpp's hooks
// are `void` virtuals (core/types.hpp Feature): a hook cannot fail an
// operation the way ts's awaited rejection can - and SdkClient::direct /
// SdkClient::graphql run no feature hooks at all (rawRequest calls
// `u->fetcher` directly). So, exactly as in go, rust and c, resolution
// happens at the TRANSPORT SEAM: `Utility::fetcher`, the one place every
// wire path crosses (entity ops through makeRequest, the raw paths through
// rawRequest, both reading the client's one Utility - features see the
// client's own Utility in init, and entities take a snapshot copy of the
// already-wrapped function). The wrapper refuses to send while the last
// resolution stands failed, which is fail-closed for the entity pipeline
// and the raw paths alike, with one implementation.
//
// WHERE THE CREDENTIAL LIVES, and why it is not the options map. The ts
// reference writes `options.apikey`; this port does NOT. prepareAuth builds
// the header from the client's options on every request, and this feature
// rewrites that header at the seam from a value it holds itself - same
// construction, same suppression rules - so `optionsMap()` stays exactly
// what the caller passed, and the raw paths and the entity path cannot
// disagree about it. go's structural rule, and in cpp it is load-bearing:
// the timeout feature runs the inner transport on a DETACHED thread
// (feature/timeout.hpp), so this wrapper genuinely is entered concurrently.
//
// THREAD SAFETY, stated because the parity table cannot check it. The
// vendored sekreto port disclaims it (Provider.hpp: the slot table is
// shared, and "this port ... does not claim to support" two threads building
// chains at once), and its read cache is a mutated std::vector. So EVERY
// touch of the chain, the credential and the exchange state happens under
// ONE mutex (`mu_`): a resolution or a token purchase runs to completion
// before another thread reads the credential, which is go's "share the one
// in-flight resolution/purchase" with the mutex doing the sharing - a thread
// that arrives during a purchase blocks, then finds a fresh token and does
// not buy again (the `current != used` check below). The inner transport is
// ALWAYS called outside the lock, so a slow request never serialises the
// others. The mutex is recursive because a token purchase may run a
// caller-supplied options.system.fetch, and a callback that re-enters this
// client (a nested direct(), say) must not deadlock on its own thread.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when
// a response status in `exchange.statuses` (401) says it is spent the
// wrapper buys another and retries the same request once. Test mode buys
// nothing and answers with a deterministic fake token.
//
// THE cpp-SPECIFIC SEAMS:
//
//   * A live provider object cannot travel in the options: sdk::Value is a
//     closed union (undef|null|bool|number|string|list|map|Injector|Modify),
//     so go's `providers: [&customProvider{}]` has no cpp spelling. The
//     answer is the `custom` pseudo-kind, as in c: a providers entry that is
//     an Injector, or a map `{ kind: "custom", lookup: <Injector>, name?:
//     "..." }`, bridged by a sekreto Provider whose lookup calls the
//     Injector the way the SDK calls options.system.fetch - args is a LIST
//     holding the secret NAME - and reads a STRING (a hit), undef/null (a
//     MISS - the chain continues) or a map `{ "__err__": "..." }` (an ERROR
//     - the operation fails). Conflating the last two is the failure this
//     library exists to prevent. The Injector itself never enters sekreto:
//     the spec carries a slot ticket in `values` and a per-feature `custom`
//     Definition (sekreto::providerplugin) builds the bridge from it, which
//     is how upstream's own provider slots work.
//
//   * The cpp core ships no HTTP client (utility/pipeline.hpp fetcher). The
//     exchange therefore uses options.system.fetch when supplied - the seam
//     every live cpp request already lives under - and otherwise
//     `secrets_rawfetch`, which lives in the GENERATED feature/secrets/
//     kinds.cpp: the vendored sekreto HTTPS client when a plugin group is
//     active, a transport error that says so when none is (see Config_cpp).
//
//   * The SDK is header-only and the vendored port is not. This header
//     declares what the port defines; the generated feature/secrets/kinds.mk
//     (read by tm/cpp/Makefile, which names no feature) has the port
//     compiled into libsdkfeature.a, and core/config.hpp includes this
//     header only when the model activates the feature - so a tree without
//     the feature never sees a sekreto declaration.
//
//   * cpp has no `extend` option (core/types.hpp), so the shipped suite
//     adopts the feature two ways: the generated makeFeature("secrets") on a
//     LIVE client, and direct construction through test/harness.hpp fhMake.

#ifndef SDK_FEATURE_SECRETS_HPP
#define SDK_FEATURE_SECRETS_HPP

#include <algorithm>
#include <cstdlib>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

// The vendored @voxgig/sekreto port (multi-TU; compiled by the Makefile into
// libsdkfeature.a through the generated kinds.mk). Its headers reach voxgig/plugin by explicit ../plugin/
// paths, so no include path is involved and no SDK header is shadowed.
#include "secrets/sekreto/Providers.hpp"
#include "secrets/sekreto/Sekreto.hpp"

namespace sdk {

// ---- the generated wiring (feature/secrets/kinds.cpp, Config_cpp) ---------
//
// Ordinary extern declarations, defined by the generated translation unit:
// the plugin definitions the model selected (type-erased, so core/config.hpp
// can declare the same function without naming a plugin type), and the
// token-exchange transport of last resort.

std::vector<std::shared_ptr<void>> secrets_plugins();

struct SecretsRawResponse {
  bool ok = false;
  int status = 0;
  std::string body;
  std::string err;
};

SecretsRawResponse secrets_rawfetch(
    const std::string& method, const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    const std::string& body);


// ---- the custom-provider bridge --------------------------------------------

class SecretsCustomProvider : public sekreto::Provider {
public:
  explicit SecretsCustomProvider(Value fn) : fn_(std::move(fn)) {}

  std::optional<std::string> lookup(const std::string& name) override {
    vs::Injection inj(Value::undef(), Value::undef());
    Value got = fn_.as_injector()(inj, vlist({Value(name)}), std::string(""), Value::undef());
    if (got.is_string()) return got.as_string();
    if (got.is_map()) {
      Value emsg = getp(got, "__err__");
      if (emsg.is_string()) throw sekreto::SekretoError(emsg.as_string());
    }
    // undef, null, or anything that is not a value: a MISS.
    return std::nullopt;
  }

  std::string describe() const override { return "custom"; }

private:
  Value fn_;
};


class SecretsFeature : public BaseFeature {
public:
  using Fetcher = std::function<Value(CtxPtr, const std::string&, const Value&)>;

  struct Exchange {
    std::string path = "auth/token";
    std::string method = "POST";
    std::string request = "refresh_token";
    std::string response = "access_token";
    std::vector<int> statuses;
    int retries = 1;
  };

  struct Track {
    long long resolves = 0; // chain resolutions that completed (hit or miss)
    long long buys = 0;     // token purchases (test mode included)
    long long refused = 0;  // requests the fail-closed gate refused to send
  };

  SdkClient* client = nullptr;
  Value options = Value::undef();

  SecretsFeature() : BaseFeature("secrets", "0.1.0", true) {}

  // Init is sync by feature contract: build the chain, never look anything
  // up here.
  void init(CtxPtr ctx, const Value& options_) override {
    options = options_;
    active = fopt::foptBool(options, "active", false);
    if (!active) return;

    client = ctx->client;
    // The LIVE options map (the root context's, which IS client->options):
    // read for `apikey` and `auth`, never written.
    liveopts_ = (nullptr != client && client->options.is_map()) ? client->options : ctx->options;

    // WRAP FIRST. The fail-closed gate needs the seam whatever happens
    // below - a chain that fails to build must still refuse to send - so
    // the wrapper is installed before anything here can fail, and the
    // exchange (when on) additionally needs to SEE responses: expiry is
    // only ever discovered from one, and this is the one place a response
    // can be seen and the request tried again.
    Fetcher inner = ctx->utility->fetcher;
    SecretsFeature* self = this;
    ctx->utility->fetcher = [self, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      return self->transport(ctx2, url, fetchdef, inner);
    };

    secretname_ = fopt::foptStr(options, "name", "apikey");
    cache_ = fopt::foptBool(options, "cache", true);

    // Exchange config, normalised once. Null when off, so every later
    // decision is a null check.
    Value xopts = fopt::foptMap(options, "exchange");
    if (fopt::foptBool(xopts, "active", false)) {
      auto x = std::make_shared<Exchange>();
      x->path = fopt::foptStr(xopts, "path", "auth/token");
      x->method = fopt::foptStr(xopts, "method", "POST");
      x->request = fopt::foptStr(xopts, "request", "refresh_token");
      x->response = fopt::foptStr(xopts, "response", "access_token");
      x->retries = fopt::foptInt(xopts, "retries", 1);
      Value sl = fopt::foptList(xopts, "statuses");
      if (sl.is_list()) {
        for (const auto& s : *sl.as_list()) {
          if (s.is_number()) x->statuses.push_back(static_cast<int>(s.as_int()));
        }
      }
      if (x->statuses.empty()) x->statuses.push_back(401);
      exchange_ = x;
    }

    // The explicit credential, when set, is the first store in the chain.
    //
    // WHICH option that is depends on the exchange. Without one, the secret
    // being resolved IS the credential the transport sends, so `apikey` is
    // it. With one, the secret is a REFRESH token and `apikey` means the
    // opposite thing - an access token the caller already holds - so the
    // explicit seat belongs to `exchange.refresh`, and apikey is left alone
    // to serve as the starting access token (see resolve).
    //
    // Read with mapget, not foptStr: an explicitly EMPTY apikey means
    // "defer to the chain", and foptStr would answer its default for it.
    std::string explicitcred;
    if (!exchange_) {
      Value a = mapget(liveopts_, "apikey");
      if (a.is_string()) explicitcred = a.as_string();
    } else {
      Value r = getp(xopts, "refresh");
      if (r.is_string()) explicitcred = r.as_string();
    }

    std::vector<sekreto::ProviderSpec> specs;

    if (!explicitcred.empty()) {
      try {
        std::string key = sekreto::envkey(secretname_, "");
        sekreto::ProviderSpec seat;
        seat.kind = "memory";
        seat.name = "options";
        seat.values.set(key, explicitcred);
        specs.push_back(seat);
      } catch (const std::exception& e) {
        fail(e.what());
      }
    }

    Value providers = fopt::foptList(options, "providers");
    if (providers.is_list()) {
      for (const Value& p : *providers.as_list()) {
        if (p.is_injector()) {
          // A provider already built (as built as cpp can spell it): joins
          // the chain as it is.
          specs.push_back(customSpec(p, ""));
        } else if (p.is_map()) {
          Value kind = getp(p, "kind");
          if (kind.is_string() && "custom" == kind.as_string()) {
            Value lookup = getp(p, "lookup");
            if (!lookup.is_injector()) {
              fail("sekreto: not a provider or a provider spec: " + vs::jsonify(p, 0) +
                   " (a `custom` provider needs a `lookup` callable)");
              continue;
            }
            specs.push_back(customSpec(lookup, as_str(getp(p, "name"))));
          } else {
            try {
              specs.push_back(sekreto::specof(toPluginValue(p)));
            } catch (const std::exception& e) {
              fail(e.what());
            }
          }
        } else {
          // FAIL CLOSED, never drop. An entry that is neither a callable
          // nor a spec map (a bare "hashicorp" where a spec was meant, a
          // number, a null) must not leave the chain quietly shorter than
          // the options say: sekreto's own wording lands in the
          // init-failure gate, which refuses to send. A loop that skipped
          // the entry would SHORTEN the chain instead of failing it - a
          // misconfigured providers list then sends ordinary
          // unauthenticated requests, the exact fail-open the gate exists
          // to prevent. (ts/kotlin push every entry through to Sekreto's
          // constructor, whose dynamic list refuses it with this message;
          // cpp's SekretoOptions::providers is a typed vector, so the
          // feature raises the library's wording itself, as go and rust do.)
          fail("sekreto: not a provider or a provider spec: " + vs::jsonify(p, 0));
        }
      }
    }

    if (!initerr_.empty()) return;

    // The plugin DEFINITIONS the model selected for this feature, from the
    // generated feature/secrets/kinds.cpp. Upstream sekreto's contract
    // since the registry was retired: a kind not passed here is unknown to
    // this Sekreto, so the model's choice of plugin groups IS the SDK's
    // provider vocabulary. The `custom` bridge is added only when a custom
    // entry needs it.
    std::vector<sekreto::Definition> defs;
    for (const auto& erased : secrets_plugins()) {
      defs.push_back(std::static_pointer_cast<plugin::Definition>(erased));
    }
    if (!customs_.empty()) defs.push_back(customDefinition());

    sekreto::SekretoOptions sopts;
    sopts.providers = specs;
    sopts.plugins = defs;
    sopts.cache = cache_;

    try {
      sek_ = std::make_shared<sekreto::Sekreto>(sopts);
    } catch (const std::exception& e) {
      // Init cannot fail the construction the way ts's throwing init does;
      // the transport gate refuses to send instead, which keeps a
      // misconfigured chain fail-closed rather than silently
      // unauthenticated.
      fail(e.what());
    }
  }

  // ---- accessors ------------------------------------------------------------

  // The LIVE chain (the cpp spelling of ts's `sekreto()` accessor - named
  // `chain` because a member called `sekreto` would shadow the namespace),
  // or null when the feature is inactive or its construction failed. Never
  // a clone: sekreto holds provider state that has to stay live to be worth
  // anything. Not thread-safe to USE concurrently with requests; see the
  // header note.
  std::shared_ptr<sekreto::Sekreto> chain() const {
    std::lock_guard<std::recursive_mutex> lk(mu_);
    return sek_;
  }

  // The resolved credential ("" when none) - the value the transport
  // wrapper injects into each request. Read here rather than from the
  // options map, which this feature never mutates.
  std::string credential() const {
    std::lock_guard<std::recursive_mutex> lk(mu_);
    return cred_;
  }

  // sekreto's own message when the chain could not be built (an unknown
  // kind, a malformed providers entry, a provider refusing its
  // configuration), or "". While it is set the transport wrapper refuses
  // to send.
  std::string initError() const {
    std::lock_guard<std::recursive_mutex> lk(mu_);
    return initerr_;
  }

  Track track() const {
    std::lock_guard<std::recursive_mutex> lk(mu_);
    return track_;
  }

  // The client's secrets feature, or null when the client has none. Walks
  // the client's feature list by name, so it finds the instance the
  // generated config installed from the options - never a second one.
  static std::shared_ptr<SecretsFeature> of(SdkClient* client) {
    if (nullptr == client) return nullptr;
    for (const auto& f : client->features) {
      if (f && "secrets" == f->getName()) {
        return std::dynamic_pointer_cast<SecretsFeature>(f);
      }
    }
    return nullptr;
  }

private:
  Value liveopts_ = Value::undef();
  std::string secretname_ = "apikey";
  bool cache_ = true;

  std::shared_ptr<sekreto::Sekreto> sek_;
  std::string initerr_;

  // The RESOLVED credential (the access token when exchanging), held here
  // and injected at the seam - never written into the options map. A
  // cached resolution stands (cache: true only); a FAILURE never sets it,
  // so the next request asks the chain again.
  std::string cred_;
  bool resolved_ = false;

  std::shared_ptr<Exchange> exchange_;
  std::string refresh_;

  // The custom-provider slot table: the Injector each `custom` spec's slot
  // ticket names.
  std::vector<Value> customs_;

  Track track_;
  mutable std::recursive_mutex mu_;

  // The FIRST failure stands: it names the entry the caller has to fix.
  void fail(const std::string& msg) {
    if (initerr_.empty()) initerr_ = msg;
  }

  // ---- options map -> sekreto ------------------------------------------------

  // An SDK Value as the plugin value model sekreto::specof reads. `values`
  // (memory's literal map) is coerced to strings, as every port does.
  static plugin::V toPluginValue(const Value& v, bool stringleaves = false) {
    if (v.is_string()) return plugin::vstr(v.as_string());
    if (v.is_list()) {
      plugin::V l = plugin::vlist();
      for (const auto& e : *v.as_list()) plugin::push(l, toPluginValue(e, stringleaves));
      return l;
    }
    if (v.is_map()) {
      plugin::V m = plugin::vmap();
      for (const auto& kv : *v.as_map()) {
        // Containers recurse; only the LEAVES under `values` are coerced.
        plugin::set(m, kv.first,
                    toPluginValue(kv.second, stringleaves || "values" == kv.first));
      }
      return m;
    }
    if (stringleaves) return plugin::vstr(Struct::stringify(v));
    if (v.is_bool()) return plugin::vbool(v.as_bool());
    if (v.is_number()) return plugin::vnum(v.as_double());
    return plugin::vnull();
  }

  sekreto::ProviderSpec customSpec(const Value& fn, const std::string& name) {
    sekreto::ProviderSpec spec;
    spec.kind = "custom";
    spec.name = name;
    spec.values.set("slot", std::to_string(customs_.size()));
    customs_.push_back(fn);
    return spec;
  }

  sekreto::Definition customDefinition() {
    SecretsFeature* self = this;
    return sekreto::providerplugin("custom",
      [self](const sekreto::ProviderSpec& spec) -> std::shared_ptr<sekreto::Provider> {
        std::optional<std::string> slot = spec.values.get("slot");
        size_t index = slot.has_value() ? static_cast<size_t>(std::atol(slot->c_str()))
                                        : self->customs_.size();
        if (index >= self->customs_.size()) {
          throw sekreto::SekretoError("sekreto: custom provider has no lookup callable");
        }
        return std::make_shared<SecretsCustomProvider>(self->customs_[index]);
      });
  }

  // ---- credential injection ---------------------------------------------------

  // Write the resolved credential into THIS request's authorization header,
  // the way prepareAuth builds it (same options auth.prefix, same
  // suppression rule), so the two cannot drift.
  //
  // `auth: null` is the documented way to send NO credential, and
  // prepareAuth honours it by removing the header; so does this, and it
  // never writes one - which is what keeps the exchange from transmitting
  // exactly the credential the caller suppressed on a retry. Read with
  // mapget + is_nullish exactly as prepareAuth reads it. An EMPTY
  // credential leaves prepareAuth's header alone: nothing was resolved, so
  // there is nothing to inject and nothing to retract that prepareAuth did
  // not already decide.
  void reauth(const Value& fetchdef) {
    Value headers = getp(fetchdef, "headers");
    if (!headers.is_map()) return;

    if (authSuppressed()) {
      map_remove(headers, "authorization");
      return;
    }

    if (cred_.empty()) return;

    std::string prefix = as_str(Struct::getpath(liveopts_, {"auth", "prefix"}));
    map_put(headers, "authorization",
            Value(prefix.empty() ? cred_ : prefix + " " + cred_));
  }

  bool authSuppressed() const {
    return is_nullish(mapget(liveopts_, "auth"));
  }

  // ---- the exchange -----------------------------------------------------------

  // Buy an access token with the refresh token. Answers sekreto-style: a
  // message, or "" for success with the token in cred_. Called under mu_.
  std::string buy() {
    const Exchange& x = *exchange_;

    // TEST MODE BUYS NOTHING. The test feature replaces the transport so no
    // request leaves the process; an exchange here would be the one HTTP
    // call it could not stop, and it would need a live token endpoint for a
    // suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer makeOptions gives a
    // required server variable, for the same reason.
    if (nullptr == client || "live" != client->mode) {
      cred_ = "test-" + x.response;
      track_.buys++;
      return "";
    }

    if (refresh_.empty()) {
      return "secrets: no refresh token: the provider chain has no '" + secretname_ +
             "', and feature.secrets.exchange.refresh is unset";
    }

    Value opts = client->optionsMap();

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    std::string base = as_str(getp(opts, "base"));
    while (!base.empty() && '/' == base.back()) base.pop_back();
    std::string path = x.path;
    while (!path.empty() && '/' == path.front()) path.erase(0, 1);
    std::string url = base + "/" + path;

    // The body is MARSHALLED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or newline
    // must arrive as that literal value, not as malformed JSON.
    std::string bodytext = vs::jsonify(vmap({{x.request, Value(refresh_)}}), 0);

    Value fetchdef = vmap({
      {"method", Value(x.method)},
      {"headers", vmap({{"content-type", Value(std::string("application/json"))}})},
      {"body", Value(bodytext)}});

    // Deliberately NOT the SDK transport. The transport is what this feature
    // wraps, and sending the token request back through it would recurse on
    // the first expiry - and would route the exchange through the test mock,
    // which knows nothing about it. options.system.fetch when the caller
    // supplied one (the seam every live cpp request already uses), else the
    // bundled transport of last resort from the generated kinds.cpp.
    Value sysFetch = Struct::getpath(opts, {"system", "fetch"});
    Value res;
    if (sysFetch.is_injector()) {
      try {
        vs::Injection inj(Value::undef(), Value::undef());
        res = sysFetch.as_injector()(inj, vlist({Value(url), fetchdef}), std::string(""),
                                     Value::undef());
      } catch (const SdkErrorPtr& e) {
        return e->msg;
      } catch (const std::exception& e) {
        return std::string("secrets: token exchange transport failed: ") + e.what();
      }
    } else {
      std::vector<std::pair<std::string, std::string>> hdrs{{"content-type", "application/json"}};
      SecretsRawResponse raw = secrets_rawfetch(x.method, url, hdrs, bodytext);
      if (!raw.ok) return raw.err;
      res = vmap({{"status", Value(raw.status)}, {"body", Value(raw.body)}});
    }

    int status = fopt::fresStatus(res);
    if (200 > status || 300 <= status) {
      return "secrets: token exchange failed: " + std::to_string(status) + " from " + url;
    }

    Value parsed = Value::undef();
    Value jf = mapget(res, "json");
    if (jf.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      parsed = jf.as_injector()(inj, Value::undef(), std::string(""), Value::undef());
    } else {
      Value raw = getp(res, "body");
      parsed = raw.is_string() ? vs::parse_json(raw.as_string()) : raw;
    }

    Value token = getp(parsed, x.response);
    if (!token.is_string() || token.as_string().empty()) {
      return "secrets: token exchange returned no '" + x.response + "' field from " + url;
    }

    cred_ = token.as_string();
    track_.buys++;
    return "";
  }

  bool spent(const Value& res) const {
    int status = fopt::fresStatus(res);
    if (0 > status) return false;
    return std::find(exchange_->statuses.begin(), exchange_->statuses.end(), status) !=
           exchange_->statuses.end();
  }

  // ---- resolution -------------------------------------------------------------

  // One resolution. A settled SUCCESS is kept only when caching is on
  // (`cache: false` means every request asks the chain again, and sekreto's
  // own cache is off with it); a FAILURE is never kept, so a transient
  // vault outage never poisons the client - the next request asks again.
  // Answers the provider's own message, or "". Called under mu_.
  std::string resolve() {
    if (cache_ && resolved_) return "";
    if (!sek_) return "";

    std::optional<std::string> found;
    try {
      found = sek_->tryget(secretname_);
    } catch (const std::exception& e) {
      // A provider ERROR fails the op (via the transport gate); only a MISS
      // falls through.
      return e.what();
    }
    track_.resolves++;

    if (!exchange_) {
      // A hit is the credential. An UNCACHED miss after an earlier hit is a
      // revocation: the chain now says no provider has the secret, so the
      // resolved value must not keep going out on the wire. (An explicit
      // apikey OPTION is never lost here - it seats FIRST in the chain as a
      // memory provider, so the chain HITS while one is set.)
      cred_ = found.has_value() ? found.value() : "";
      resolved_ = true;
      return "";
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit `apikey`
    // may already hold a usable access token, and the API is what gets to
    // say whether it does.
    refresh_ = found.has_value() ? found.value() : "";

    if (cred_.empty()) {
      // A starting access token supplied as the OPTION: read from the frozen
      // options map (no feature ever writes it).
      Value held = mapget(liveopts_, "apikey");
      if (held.is_string()) cred_ = held.as_string();
    }
    if (!cred_.empty()) {
      // Spend it: if it is stale the API answers with an expiry status and
      // the wrapper buys another, which is the same path expiry takes anyway.
      resolved_ = true;
      return "";
    }

    std::string berr = buy();
    if (!berr.empty()) return berr;
    resolved_ = true;
    return "";
  }

  // ---- the transport wrapper --------------------------------------------------

  Value transport(CtxPtr ctx, const std::string& url, const Value& fetchdef,
                  const Fetcher& inner) {
    bool suppressed = false;
    {
      std::lock_guard<std::recursive_mutex> lk(mu_);

      // FAIL-CLOSED, at the ONE seam every wire path crosses. Entity ops,
      // direct, graphql and the exchange retries all come through here, so
      // resolving HERE is what gives the raw paths - which run no feature
      // hooks at all - the same credential the entity pipeline gets. A
      // construction failure (initerr_) or a provider ERROR refuses the
      // request with sekreto's own message - never an unauthenticated send.
      if (!initerr_.empty()) {
        track_.refused++;
        throw ctx->makeError("secrets_init", initerr_);
      }
      std::string rerr = resolve();
      if (!rerr.empty()) {
        track_.refused++;
        throw ctx->makeError("secrets_resolve", rerr);
      }

      // Inject the resolved credential into THIS request's header (the
      // header was built by prepareAuth from the options apikey; the
      // chain-resolved value lives in feature state instead).
      reauth(fetchdef);
      suppressed = authSuppressed();
    }

    if (!exchange_) return inner(ctx, url, fetchdef);

    // `auth: null` is a deliberately unauthenticated request: a refusal of
    // it is not an expired token and cannot be fixed by buying one -
    // retrying would transmit exactly the credential the caller suppressed.
    if (suppressed) return inner(ctx, url, fetchdef);

    int max = exchange_->retries;
    int attempt = 0;
    for (;;) {
      // The credential THIS attempt goes out with, captured before it
      // leaves: it is what tells a stale refusal apart from a fresh one.
      std::string used = credential();

      Value out = inner(ctx, url, fetchdef);

      if (attempt >= max || !spent(out)) return out;

      {
        std::lock_guard<std::recursive_mutex> lk(mu_);
        // Another request may have bought a token while this one was in
        // flight (the mutex made it wait for that purchase to finish).
        // Spend what is current before buying: a second exchange for a
        // token that is already fresh is wasted, and on a provider that
        // invalidates the previous credential on issuance it breaks this
        // request's own retry.
        if (cred_.empty() || cred_ == used) {
          std::string berr = buy();
          if (!berr.empty()) {
            // The purchase failed: answer with the API's own refusal rather
            // than this one. The caller asked for data, and the refusal is
            // the more useful of the two - the exchange error is a symptom.
            return out;
          }
        }
        reauth(fetchdef);
      }
      attempt++;
    }
  }
};

} // namespace sdk

#endif // SDK_FEATURE_SECRETS_HPP
