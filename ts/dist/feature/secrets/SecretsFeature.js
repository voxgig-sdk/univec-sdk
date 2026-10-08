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
class SecretsFeature extends BaseFeature_1.BaseFeature {
    version = '0.1.0';
    name = 'secrets';
    _client;
    _sekreto;
    _secretname = 'apikey';
    _resolving;
    _cache = true;
    _exchange = null;
    _refresh;
    _buying;
    init(ctx, fopts) {
        const client = ctx.client;
        const options = ctx.options;
        this._client = client;
        this._secretname = 'string' === typeof fopts.name &&
            '' !== fopts.name ? fopts.name : 'apikey';
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
        const explicit = null == this._exchange ?
            options.apikey :
            (null == xopts ? undefined : xopts.refresh);
        if ('string' === typeof explicit && '' !== explicit) {
            this._register(explicit);
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
        if (null != this._exchange) {
            const self = this;
            const utility = ctx.utility;
            const inner = utility.fetcher;
            utility.fetcher = async function (ctx2, url, fetchdef) {
                return self._withRefresh(ctx2, url, fetchdef, inner);
            };
        }
    }
    sekreto() {
        return this._sekreto;
    }
    _register(value) {
        const ctx = this._client._rootctx;
        if (null != ctx && null != ctx.utility && 'function' === typeof ctx.utility.cleanAdd) {
            ctx.utility.cleanAdd(ctx, value);
        }
    }
    PreSpec(_ctx) {
        return this.resolve();
    }
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
        this._register(found);
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
        if (null == this._client.options().auth) {
            return false;
        }
        this._client._options.apikey = await this._buy();
        return true;
    }
    _buy() {
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
        const base = String(options.base || "").replace(/\/+$/, "");
        const url = base + "/" + String(x.path).replace(/^\/+/, "");
        const fetch = options.system && options.system.fetch;
        if ("function" !== typeof fetch) {
            throw new Error("secrets: no fetch implementation for the token exchange");
        }
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
        this._register(token);
        return token;
    }
    async _withRefresh(ctx, url, fetchdef, inner) {
        const x = this._exchange;
        const max = null == x ? 0 : x.retries;
        if (null == this._client.options().auth) {
            return inner(ctx, url, fetchdef);
        }
        let attempt = 0;
        for (;;) {
            const used = this._client._options.apikey;
            const res = await inner(ctx, url, fetchdef);
            if (attempt >= max || !this._spent(res)) {
                return res;
            }
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