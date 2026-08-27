"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ClienttrackFeature = void 0;
const BaseFeature_1 = require("../base/BaseFeature");
// Client tracking. Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a
// `User-Agent`, an `X-Client-Id` (session), and a fresh per-request
// `X-Request-Id`. This lets a server correlate all traffic from one SDK
// instance and each individual call. Header names, client name/version and
// the id generator are configurable; the session id and request counter are
// exposed on `client._clienttrack`.
class ClienttrackFeature extends BaseFeature_1.BaseFeature {
    version = '0.0.1';
    name = 'clienttrack';
    active = true;
    _client;
    _options = {};
    _session = '';
    _requests = 0;
    init(ctx, options) {
        this._client = ctx.client;
        this._options = options || {};
        this.active = options.active;
        this._requests = 0;
    }
    PostConstruct(_ctx) {
        this._session = this._options.sessionId || this._genid('session');
        const client = this._client;
        client._clienttrack = {
            session: this._session,
            requests: 0,
            clientName: this._name(),
        };
    }
    PreRequest(ctx) {
        const spec = ctx.spec;
        if (null == spec) {
            return;
        }
        if (null == spec.headers) {
            spec.headers = {};
        }
        if ('' === this._session) {
            this._session = this._options.sessionId || this._genid('session');
        }
        const h = this._options.headers || {};
        this._requests++;
        const requestId = this._genid('request');
        this._set(spec.headers, h.agent || 'User-Agent', this._name());
        this._set(spec.headers, h.client || 'X-Client-Id', this._session);
        spec.headers[h.request || 'X-Request-Id'] = requestId;
        const client = this._client;
        if (null == client._clienttrack) {
            client._clienttrack = { session: this._session, requests: 0, clientName: this._name() };
        }
        client._clienttrack.requests = this._requests;
        client._clienttrack.lastRequestId = requestId;
    }
    // Do not clobber a caller-provided value (e.g. a custom User-Agent).
    _set(headers, name, value) {
        const lower = name.toLowerCase();
        for (const k of Object.keys(headers)) {
            if (k.toLowerCase() === lower) {
                return;
            }
        }
        headers[name] = value;
    }
    _name() {
        const name = this._options.clientName || 'Univec-SDK';
        const version = this._options.clientVersion || '0.0.1';
        return name + '/' + version;
    }
    _genid(kind) {
        const idgen = this._options.idgen;
        if ('function' === typeof idgen) {
            return idgen(kind);
        }
        const h = () => (1e7 * Math.random() | 0).toString(16);
        return (kind.charAt(0) + '-' + h() + h() + h()).slice(0, 20);
    }
}
exports.ClienttrackFeature = ClienttrackFeature;
//# sourceMappingURL=ClienttrackFeature.js.map