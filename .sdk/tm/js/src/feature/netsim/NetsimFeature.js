

const { BaseFeature } = require('../base/BaseFeature')


// Network behaviour simulation. Wraps the active transport (the live
// `fetch` or the `test` feature's in-memory mock) and injects realistic
// network conditions so offline unit tests can exercise slowness,
// transient failures, rate limiting and outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests
// are reproducible without mocking timers. `failRate` adds optional
// pseudo-random failures via a seeded LCG for coverage-style testing.
class NetsimFeature extends BaseFeature {
  version = '0.0.1'
  name = 'netsim'
  active = true

  _client
  _options = {}
  _calls = 0
  _seed = 1


  init(ctx, options) {
    this._client = ctx.client
    this._options = options || {}
    this.active = options.active
    this._seed = (this._options.seed | 0) || 1

    if (!this.active) {
      return
    }

    const self = this
    const utility = ctx.utility
    const inner = utility.fetcher

    utility.fetcher = async function (ctx2, url, fetchdef) {
      return self._simulate(ctx2, url, fetchdef, inner)
    }
  }


  async _simulate(ctx, url, fetchdef, inner) {
    const opts = this._options
    this._calls++
    const call = this._calls

    // Record the simulated conditions for test/debug inspection.
    const applied = {}

    // Total outage: every call fails at the transport level.
    if (true === opts.offline) {
      await this._sleep(this._pickLatency())
      applied.offline = true
      this._track(ctx, applied)
      return ctx.error('netsim_offline', 'Simulated network offline (URL was: "' + url + '")')
    }

    // Connection-level errors for the first N calls (e.g. ECONNRESET).
    if (call <= (opts.errorTimes | 0)) {
      await this._sleep(this._pickLatency())
      applied.error = true
      this._track(ctx, applied)
      return ctx.error('netsim_conn', 'Simulated connection error (call ' + call + ')')
    }

    // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
    if (call <= (opts.rateLimitTimes | 0)) {
      await this._sleep(this._pickLatency())
      applied.rateLimited = true
      this._track(ctx, applied)
      return this._respond(ctx, 429, undefined, {
        statusText: 'Too Many Requests',
        headers: { 'retry-after': String(null == opts.retryAfter ? 0 : opts.retryAfter) },
      })
    }

    // Retryable failure status for the first N calls, or every Nth call.
    const failStatus = null == opts.failStatus ? 503 : opts.failStatus
    const failByCount = call <= (opts.failTimes | 0)
    const failByEvery = 0 < (opts.failEvery | 0) && 0 === call % opts.failEvery
    const failByRate = 0 < (opts.failRate || 0) && this._rand() < opts.failRate
    if (failByCount || failByEvery || failByRate) {
      await this._sleep(this._pickLatency())
      applied.failStatus = failStatus
      this._track(ctx, applied)
      return this._respond(ctx, failStatus, undefined, { statusText: 'Simulated Failure' })
    }

    // Otherwise: apply latency then delegate to the real transport.
    const latency = this._pickLatency()
    applied.latency = latency
    this._track(ctx, applied)
    await this._sleep(latency)
    return inner(ctx, url, fetchdef)
  }


  // Latency in ms: a fixed number, or a uniform sample from {min,max}.
  _pickLatency() {
    const l = this._options.latency
    if (null == l) {
      return 0
    }
    if ('number' === typeof l) {
      return l < 0 ? 0 : l
    }
    const min = l.min | 0
    const max = null == l.max ? min : l.max | 0
    if (max <= min) {
      return min
    }
    return min + Math.floor(this._rand() * (max - min))
  }


  _sleep(ms) {
    if (null == ms || 0 >= ms) {
      return Promise.resolve()
    }
    const sleep = this._options.sleep
    if ('function' === typeof sleep) {
      return Promise.resolve(sleep(ms))
    }
    return new Promise((r) => setTimeout(r, ms))
  }


  // Deterministic 0..1 pseudo-random via a linear congruential generator.
  _rand() {
    this._seed = (this._seed * 1103515245 + 12345) & 0x7fffffff
    return this._seed / 0x7fffffff
  }


  _track(ctx, applied) {
    const struct = ctx.utility.struct
    const getprop = struct.getprop
    const client = this._client
    if (null == client._netsim) {
      client._netsim = { calls: 0, applied: [] }
    }
    client._netsim.calls++
    client._netsim.applied.push(applied)
    if (ctx.ctrl && ctx.ctrl.explain) {
      ctx.ctrl.explain.netsim = getprop(client, '_netsim')
    }
  }


  // Build a transport-shaped response (matching the test feature's mock)
  // with a header iterator the result pipeline understands.
  _respond(ctx, status, data, extra) {
    const struct = ctx.utility.struct
    const merge = struct.merge
    const getdef = struct.getdef

    const out = merge([
      {
        status,
        statusText: 'OK',
        json: async () => data,
        body: 'not-used',
      },
      getdef(extra, {}),
    ])

    const headers = struct.getprop(out, 'headers', {})
    out.headers = {
      get(key) {
        return headers[String(key).toLowerCase()]
      },
      forEach(callback) {
        Object.keys(headers).forEach((key) => callback(headers[key], key, this))
      },
    }

    return out
  }
}


module.exports = {
  NetsimFeature
}
