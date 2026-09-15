"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.SecretsFeature = void 0;
const BaseFeature_1 = require("../base/BaseFeature");
const sekreto_1 = require("./sekreto");
// The plugin DEFINITIONS the model selected for this feature, emitted by
// Config generically from the catalogue's active `plugin.def` entries.
// Upstream sekreto's contract since the registry was retired: a kind not
// passed in `plugins` is unknown to that Sekreto, so the model's choice of
// plugin groups IS the SDK's provider vocabulary.
const Config_1 = require("../../Config");
// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider — a `memory` store named `options` — so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
// When the option is unset, the remaining providers (env, dotenv, a vault)
// are asked in order, and moving a credential from code to a vault becomes
// a configuration change.
//
// SOME APIs will not take a long-lived credential at all. What the chain
// resolves is then a REFRESH token, which buys a short-lived ACCESS token
// from a token endpoint; the access token is what every request carries,
// and it expires. `exchange.active` turns that round trip on: the resolved
// secret is POSTed to `exchange.path` (relative to options.base), the
// access token from the response is written to options.apikey, and a
// response in `exchange.statuses` (401) buys another and retries once.
//
// That last part is why this feature wraps the transport. Expiry is only
// ever discovered from a RESPONSE, and the transport is the one place a
// response can be seen before the operation pipeline turns it into a
// result. With the exchange off, nothing is wrapped.
//
// Resolution is ASYNC (providers may do IO), but the auth header is built
// by the synchronous prepareAuth inside makeSpec. The bridge is the
// feature hook pipeline: every entity op awaits featureHook('PreSpec')
// before calling makeSpec, so the PreSpec hook below resolves the secret
// once and writes it into the live options where prepareAuth already
// looks. prepareAuth itself is untouched. SolardemoSDK.prepare() bypasses
// feature hooks entirely, so it awaits client._secrets.resolve() itself.
class SecretsFeature extends BaseFeature_1.BaseFeature {
    version = '0.1.0';
    name = 'secrets';
    _client;
    _sekreto;
    _secretname = 'apikey';
    _resolving;
    _cache = true;
    // Exchange state. `_exchange` is the resolved config (null when off),
    // `_refresh` the credential the chain gave us, and `_buying` the single
    // in-flight token purchase concurrent callers share.
    _exchange = null;
    _refresh;
    _buying;
    // Sync by contract (the constructor cannot await): build the chain only,
    // never look anything up here.
    init(ctx, fopts) {
        const client = ctx.client;
        const options = ctx.options;
        this._client = client;
        this._secretname = 'string' === typeof fopts.name &&
            '' !== fopts.name ? fopts.name : 'apikey';
        // Exchange config, normalised once. Null when off, so every later
        // decision is a null check rather than a repeated `true === ...active`.
        const xopts = fopts.exchange;
        this._exchange = (null != xopts && true === xopts.active) ? {
            path: 'string' === typeof xopts.path ? xopts.path : 'auth/token',
            method: 'string' === typeof xopts.method ? xopts.method : 'POST',
            request: 'string' === typeof xopts.request ? xopts.request : 'refresh_token',
            response: 'string' === typeof xopts.response ? xopts.response : 'access_token',
            statuses: Array.isArray(xopts.statuses) ? xopts.statuses : [401],
            retries: 'number' === typeof xopts.retries ? xopts.retries : 1,
        } : null;
        const providers = [];
        // The explicit credential, when set, is the first store in the chain.
        //
        // WHICH option that is depends on the exchange. Without one, the secret
        // being resolved IS the credential the transport sends, so `apikey` is
        // it. With one, the secret is a REFRESH token and `apikey` means the
        // opposite thing — an access token the caller already holds — so the
        // explicit seat belongs to `exchange.refresh`, and apikey is left alone
        // to serve as the starting access token (see resolve below).
        const explicit = null == this._exchange ?
            options.apikey :
            (null == xopts ? undefined : xopts.refresh);
        if ('string' === typeof explicit && '' !== explicit) {
            providers.push({
                kind: 'memory',
                name: 'options',
                values: { [(0, sekreto_1.envkey)(this._secretname)]: explicit },
            });
        }
        for (const p of (fopts.providers || [])) {
            providers.push(p);
        }
        this._cache = false !== fopts.cache;
        this._sekreto = new sekreto_1.Sekreto({
            providers,
            plugins: Config_1.FEATURE_PLUGINS[this.name] || [],
            cache: this._cache,
        });
        client._secrets = this;
        // Wrap the transport ONLY when there is an exchange to defend. A spent
        // access token is discovered from the response, and this is the one
        // place a response can be seen and the request tried again.
        if (null != this._exchange) {
            const self = this;
            const utility = ctx.utility;
            const inner = utility.fetcher;
            utility.fetcher = async function (ctx2, url, fetchdef) {
                return self._withRefresh(ctx2, url, fetchdef, inner);
            };
        }
    }
    // The LIVE Sekreto instance, for the SDK's secrets() accessor and for
    // callers who want arbitrary secrets or redaction:
    //
    //   await sdk.secrets().get('db.password')
    //   sdk.secrets().redact(logline)
    //
    // Public, so the accessor does not have to reach into a private field.
    // Never a clone: sekreto holds provider state (caches, vault leases)
    // that has to stay live to be worth anything.
    sekreto() {
        return this._sekreto;
    }
    PreSpec(_ctx) {
        return this.resolve();
    }
    // Resolve the apikey before the first request. Concurrent ops share the
    // one IN-FLIGHT promise; a settled one is not reused unless caching is
    // on. A provider ERROR (unreachable vault, bad creds) rejects and fails
    // the op — sekreto's miss-vs-error rule: never fall through to an
    // unauthenticated request because a store was broken.
    //
    // The promise is cleared on REJECTION, after success when caching is off,
    // and after a MISS however caching is set. Holding a settled promise
    // forever would mean a transient vault outage poisoned the client
    // permanently — every later operation failing with the original error long
    // after the vault recovered — and it would make the documented
    // `cache: false` a lie, since the chain would never be asked a second time.
    //
    // The MISS rule is sekreto's, not this feature's: `A miss is never cached:
    // the next read asks again`, in sekreto's own source. Retaining a settled
    // miss here would override that from the layer above, and a secret
    // provisioned after startup — a mounted file, a policy granted a minute
    // late — would never be picked up for the life of the client. `cache` is
    // about caching a HIT; it was never a promise to keep saying no.
    resolve() {
        if (null == this._resolving) {
            const inflight = this._resolveonce()
                .then((hit) => {
                if (!this._cache || !hit) {
                    this._resolving = undefined;
                }
            }, (err) => {
                this._resolving = undefined;
                throw err;
            });
            this._resolving = inflight;
        }
        return this._resolving;
    }
    // Resolve once, reporting whether a credential came out of it. That
    // boolean is the whole of what resolve() needs to tell a cacheable HIT
    // from a miss it must not retain.
    async _resolveonce() {
        if (null == this._sekreto) {
            return false;
        }
        const found = await this._sekreto.try(this._secretname);
        if (null == this._exchange) {
            if (undefined !== found) {
                // The same live-mutation seam TestFeature uses for the transport:
                // prepareAuth reads client.options() (a clone of _options), so the
                // resolved value lands where the sync auth path already looks.
                this._client._options.apikey = found;
            }
            return undefined !== found;
        }
        // Exchanging: what the chain resolved is the REFRESH token, kept for
        // every later purchase. A miss is not fatal here — an explicit
        // `apikey` may already hold a usable access token, and the API is
        // what gets to say whether it does.
        this._refresh = undefined === found ? undefined : String(found);
        const apikey = this._client._options.apikey;
        if ('string' === typeof apikey && '' !== apikey) {
            // A starting access token was supplied. Spend it: if it is stale the
            // API answers 401 and the transport wrapper buys another, which is
            // the same path expiry takes anyway.
            return true;
        }
        // `auth: null` is the documented way to send NO credential, and a
        // purchase is a credential-bearing call: the refresh token goes to the
        // token endpoint in the request body. _withRefresh honours suppression
        // for the RETRY, but it runs after this — by then the refresh token has
        // already left the process, and no later check can call it back. The
        // suppression has to be honoured here, before the first purchase, or it
        // only ever half-held.
        if (null == this._client.options().auth) {
            return false;
        }
        this._client._options.apikey = await this._buy();
        return true;
    }
    // Buy an access token with the refresh token.
    //
    // Concurrent callers share the ONE in-flight purchase: a client running
    // four operations at once must not open four token requests, and three of
    // the four tokens would be wasted. The promise is cleared once settled,
    // so the next expiry buys a fresh one rather than replaying this result.
    _buy() {
        // TEST MODE BUYS NOTHING.
        //
        // The test feature replaces the transport so that no request leaves the
        // process; an exchange here would be the one HTTP call it could not
        // stop, and it would need a live token endpoint for a suite whose whole
        // point is not needing one. So test mode gets a deterministic,
        // obviously-fake token instead — the same answer makeOptions gives a
        // required server variable, for the same reason.
        if ('live' !== this._client._mode) {
            return Promise.resolve('test-' + this._exchange.response);
        }
        if (null != this._buying) {
            return this._buying;
        }
        const buying = this._buyonce()
            .then((token) => {
            this._buying = undefined;
            return token;
        }, (err) => {
            this._buying = undefined;
            throw err;
        });
        this._buying = buying;
        return buying;
    }
    async _buyonce() {
        const x = this._exchange;
        if (null == this._refresh || "" === this._refresh) {
            throw new Error("secrets: no refresh token: the provider chain has no '" +
                this._secretname + "', and feature.secrets.exchange.refresh is unset");
        }
        const options = this._client.options();
        // The token endpoint is RELATIVE to the base, which already carries
        // whatever account or tenant segment the server URL declares.
        const base = String(options.base || "").replace(/\/+$/, "");
        const url = base + "/" + String(x.path).replace(/^\/+/, "");
        const fetch = options.system && options.system.fetch;
        if ("function" !== typeof fetch) {
            throw new Error("secrets: no fetch implementation for the token exchange");
        }
        // Deliberately NOT the SDK transport. The transport is what this
        // feature wraps, and sending the token request back through it would
        // recurse on the first 401 — and would route the exchange through the
        // test mock, which knows nothing about it.
        const res = await fetch(url, {
            method: x.method,
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ [x.request]: this._refresh }),
        });
        const status = null == res ? 0 : res.status;
        if (200 > status || 300 <= status) {
            throw new Error("secrets: token exchange failed: " + status + " from " + url);
        }
        const body = "function" === typeof res.json ? await res.json() : res.body;
        const token = null == body ? undefined : body[x.response];
        if ("string" !== typeof token || "" === token) {
            throw new Error("secrets: token exchange returned no '" + x.response + "' field from " + url);
        }
        return token;
    }
    // Buy a token and try the request again when the API says the current one
    // is spent. Wraps the transport; installed only when exchanging.
    //
    // The retry rewrites the Authorization header IN PLACE on the fetchdef,
    // because the header was built by the synchronous prepareAuth before this
    // request left, and it carries the token that just failed. Rebuilt the
    // way prepareAuth builds it, from the same options.auth.prefix, so the
    // two cannot drift.
    async _withRefresh(ctx, url, fetchdef, inner) {
        const x = this._exchange;
        const max = null == x ? 0 : x.retries;
        // `auth: null` is the documented way to send NO credential, and
        // prepareAuth honours it by removing the header. A refusal of a
        // deliberately unauthenticated request is not an expired token and
        // cannot be fixed by buying one — retrying would transmit exactly the
        // credential the caller suppressed.
        if (null == this._client.options().auth) {
            return inner(ctx, url, fetchdef);
        }
        let attempt = 0;
        for (;;) {
            // The credential THIS attempt goes out with, captured before it
            // leaves: it is what tells a stale refusal apart from a fresh one.
            const used = this._client._options.apikey;
            const res = await inner(ctx, url, fetchdef);
            if (attempt >= max || !this._spent(res)) {
                return res;
            }
            // Another request may have bought a token while this one was in
            // flight. Concurrent 401s share the in-flight purchase, but
            // STAGGERED ones do not: the first finishes and clears it, and the
            // second would then buy again — a second exchange for a token that
            // is already current, and on a provider that invalidates the
            // previous credential on issuance, one that breaks the first
            // request's own retry. So spend what is current before buying.
            const current = this._client._options.apikey;
            let token;
            if ('string' === typeof current && '' !== current && current !== used) {
                token = current;
            }
            else {
                try {
                    token = await this._buy();
                }
                catch (err) {
                    // The purchase failed: answer with the API's own refusal rather
                    // than this one. The caller asked for data, and the 401 is the
                    // more useful of the two — the exchange error is a symptom.
                    return res;
                }
                this._client._options.apikey = token;
            }
            this._reauth(fetchdef, token);
            attempt++;
        }
    }
    _spent(res) {
        if (null == res || res instanceof Error) {
            return false;
        }
        const statuses = this._exchange.statuses;
        return statuses.indexOf(res.status) >= 0;
    }
    _reauth(fetchdef, token) {
        if (null == fetchdef || null == fetchdef.headers) {
            return;
        }
        const auth = this._client.options().auth;
        // Suppressed auth means NO header, the same answer prepareAuth gives.
        // Reached defensively - _withRefresh does not retry at all when auth
        // is null - but this is the function that writes the credential, so
        // it is where the rule has to hold.
        if (null == auth) {
            delete fetchdef.headers.authorization;
            return;
        }
        const prefix = auth.prefix;
        fetchdef.headers.authorization = prefix ? prefix + " " + token : token;
    }
}
exports.SecretsFeature = SecretsFeature;
//# sourceMappingURL=SecretsFeature.js.map