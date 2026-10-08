"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.CostFeature = void 0;
const BaseFeature_1 = require("../base/BaseFeature");
class CostFeature extends BaseFeature_1.BaseFeature {
    version = '0.0.1';
    name = 'cost';
    active = true;
    _client;
    _options = {};
    _pending = new WeakMap();
    _seq = 0;
    init(ctx, options) {
        this._client = ctx.client;
        this._options = options || {};
        this.active = options.active;
        this._pending = new WeakMap();
        this._seq = 0;
        const limit = this._limit();
        const client = this._client;
        if (null == client._cost) {
            client._cost = {
                currency: this._options.currency || 'USD',
                total: { calls: 0, attempts: 0, amount: 0, reported: 0, estimated: 0 },
                ops: {},
                actors: {},
                budget: { limit, spent: 0, remaining: limit, exceeded: false },
                last: undefined,
            };
        }
        if (!this.active) {
            return;
        }
        const self = this;
        const utility = ctx.utility;
        const inner = utility.fetcher;
        utility.fetcher = async function (ctx2, url, fetchdef) {
            return self._charge(ctx2, url, fetchdef, inner);
        };
    }
    // Budget gate. Runs before endpoint resolution, so a refused call costs
    // nothing at all.
    PrePoint(ctx) {
        if (!this.active) {
            return;
        }
        let pending = this._pending.get(ctx);
        if (null == pending) {
            pending = this._newPending();
            this._pending.set(ctx, pending);
        }
        pending.piped = true;
        const limit = this._limit();
        if (0 >= limit) {
            return;
        }
        const client = this._client;
        const cost = client._cost;
        if (cost.total.amount < limit) {
            return;
        }
        cost.budget.exceeded = true;
        if ('deny' !== this._options.onBudget) {
            return;
        }
        const err = ctx.error('cost_budget', 'Cost budget of ' + limit + ' ' + cost.currency + ' is spent (' +
            cost.total.amount + ' ' + cost.currency + ' used)');
        // Short-circuit endpoint resolution; the pipeline surfaces this error.
        ctx.out.point = err;
        return err;
    }
    async _charge(ctx, url, fetchdef, inner) {
        let res;
        let threw = false;
        // A rejecting transport still costs an attempt. Without this, a run of
        // connection-level failures under `retry` (which catches the throw and
        // tries again) would be charged nothing at all, and an onBudget: 'deny'
        // ceiling could never stop it.
        try {
            res = await inner(ctx, url, fetchdef);
        }
        catch (err) {
            threw = true;
            res = err;
        }
        const priced = this._price(ctx, res);
        const client = this._client;
        const cost = client._cost;
        let pending = this._pending.get(ctx);
        if (null == pending) {
            pending = this._newPending();
            this._pending.set(ctx, pending);
        }
        pending.attempts++;
        pending.amount += priced.amount;
        pending[('header' === priced.source || 'body' === priced.source) ?
            'reported' : 'estimated'] += priced.amount;
        pending.source = priced.source;
        cost.total.attempts++;
        if (!pending.piped) {
            this._commit(ctx, pending, '_', 'direct');
            this._pending.delete(ctx);
        }
        if (threw) {
            throw res;
        }
        return res;
    }
    _newPending() {
        return { attempts: 0, amount: 0, reported: 0, estimated: 0, source: 'none', piped: false };
    }
    // Attribute the operation's spend once the call is finished.
    PreDone(ctx) {
        this._finish(ctx, true);
    }
    // A failed operation still spent the money. When the pipeline throws,
    // PreDone never runs, so without this the attempts are counted and the
    // spend is not — and a budget could never see the cost of a call that
    // failed. Committing is once-per-operation either way: whichever hook
    // fires first consumes the pending entry.
    PreUnexpected(ctx) {
        this._finish(ctx, false);
    }
    _finish(ctx, done) {
        if (!this.active) {
            return;
        }
        const pending = this._pending.get(ctx);
        if (null == pending) {
            return;
        }
        this._pending.delete(ctx);
        if (!done && 0 === pending.attempts) {
            return;
        }
        const entity = (ctx.op && ctx.op.entity) || '_';
        const opname = (ctx.op && ctx.op.name) || '_';
        this._commit(ctx, pending, entity, opname);
    }
    _commit(ctx, pending, entity, opname) {
        const client = this._client;
        const cost = client._cost;
        let amount = pending.amount;
        let reported = pending.reported;
        let estimated = pending.estimated;
        let source = pending.source;
        // A body figure prices the whole call, so it replaces the per-attempt
        // estimate rather than adding to it — and, being server-stated, the
        // whole amount counts as reported.
        const body = this._body(ctx);
        if (null != body) {
            amount = body;
            reported = body;
            estimated = 0;
            source = 'body';
        }
        this._spend(cost, amount, reported, estimated);
        const actor = (ctx.ctrl && ctx.ctrl.actor) || this._options.actor || 'anonymous';
        cost.total.calls++;
        this._bump(cost.ops, entity + '.' + opname, amount);
        this._bump(cost.actors, actor, amount);
        this._seq++;
        const record = ctx.utility.clean(ctx, {
            seq: this._seq,
            entity,
            op: opname,
            actor,
            amount,
            currency: cost.currency,
            source,
            attempts: pending.attempts,
        });
        cost.last = record;
        const sink = this._options.sink;
        if ('function' === typeof sink) {
            try {
                sink(record);
            }
            catch (_e) { }
        }
    }
    // Price one attempt: a reported header figure, else the rate table, else
    // the flat unit.
    _price(ctx, res) {
        const header = this._options.header;
        if ('string' === typeof header && '' !== header) {
            const v = this._header(res, header);
            if (null != v) {
                return { amount: v * this._perUnit(), source: 'header' };
            }
        }
        const rate = this._rate(ctx);
        if (null != rate) {
            return { amount: rate, source: 'table' };
        }
        const unit = this._options.unit;
        if ('number' === typeof unit && 0 !== unit) {
            return { amount: unit, source: 'unit' };
        }
        return { amount: 0, source: 'none' };
    }
    // The rate table uses the same lookup grammar as rbac's rules:
    // '<entity>.<op>', then '<op>', then '*'.
    _rate(ctx) {
        const rates = this._options.rates || {};
        const entity = (ctx.entity && ctx.entity.name) || (ctx.op && ctx.op.entity) || '';
        const opname = (ctx.op && ctx.op.name) || '';
        if ('number' === typeof rates[entity + '.' + opname]) {
            return rates[entity + '.' + opname];
        }
        if ('number' === typeof rates[opname]) {
            return rates[opname];
        }
        if ('number' === typeof rates['*']) {
            return rates['*'];
        }
        return null;
    }
    // A usage figure from the parsed result body, priced by perUnit. Read
    // here, not at the transport seam, because the body is one-shot.
    _body(ctx) {
        const path = this._options.path;
        if ('string' !== typeof path || '' === path) {
            return null;
        }
        const result = ctx.result;
        if (null == result || null == result.body || 'object' !== typeof result.body) {
            return null;
        }
        const v = ctx.utility.struct.getpath(result.body, path);
        const n = Number(v);
        if (null == v || isNaN(n)) {
            return null;
        }
        return n * this._perUnit();
    }
    _spend(cost, amount, reported, estimated) {
        cost.total.amount += amount;
        cost.total.reported += reported;
        cost.total.estimated += estimated;
        const limit = cost.budget.limit;
        cost.budget.spent = cost.total.amount;
        cost.budget.remaining = 0 < limit ? Math.max(0, limit - cost.total.amount) : 0;
        if (0 < limit && cost.total.amount >= limit) {
            cost.budget.exceeded = true;
        }
    }
    _bump(bucket, key, amount) {
        let b = bucket[key];
        if (null == b) {
            b = bucket[key] = { calls: 0, amount: 0 };
        }
        b.calls++;
        b.amount += amount;
    }
    _header(res, name) {
        if (null == res || null == res.headers) {
            return null;
        }
        let v;
        if ('function' === typeof res.headers.get) {
            v = res.headers.get(name.toLowerCase());
        }
        else {
            // A plain header map from a custom system.fetch keeps conventional
            // casing ('X-Request-Cost'), and HTTP header names are
            // case-insensitive, so scan rather than index. The go, perl and php
            // ports already do this.
            const lower = name.toLowerCase();
            for (const k of Object.keys(res.headers)) {
                if (k.toLowerCase() === lower) {
                    v = res.headers[k];
                    break;
                }
            }
        }
        if (null == v) {
            return null;
        }
        const n = Number(v);
        return isNaN(n) ? null : n;
    }
    _perUnit() {
        const p = this._options.perUnit;
        return 'number' === typeof p ? p : 0;
    }
    _limit() {
        const b = this._options.budget;
        return 'number' === typeof b ? b : 0;
    }
}
exports.CostFeature = CostFeature;
//# sourceMappingURL=CostFeature.js.map