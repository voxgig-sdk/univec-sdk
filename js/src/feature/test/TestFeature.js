
const { BaseFeature } = require('../base/BaseFeature')


const S_NOT_FOUND = 'Not found'


class TestFeature extends BaseFeature {
  version = '0.0.1'
  name = 'test'
  active = true

  _client
  _options


  init(ctx, options) {
    this._client = ctx.client
    this._options = options

    const struct = ctx.utility.struct
    const walk = struct.walk
    const size = struct.size
    const setprop = struct.setprop

    const entity = this._options.entity

    this._client._mode = 'test'

    // Ensure entity ids are correct.
    walk(entity, (k, v, _parent, path) => {
      if (2 === size(path)) {
        setprop(v, 'id', k)
      }
      return v
    })

    const self = this

    function testFetcher(ctx, _fullurl, _fetchdef) {
      const struct = ctx.utility.struct
      const param = ctx.utility.param

      const getprop = struct.getprop
      const clone = struct.clone
      const merge = struct.merge
      const getelem = struct.getelem
      const select = struct.select
      const delprop = struct.delprop
      const getdef = struct.getdef

      // Shape the mock payload the way the real API would, so the op's
      // response transform recovers the entity from it. A point carrying
      // `transform.res: \`body.item\`` describes an API that answers
      // `{item: {...}}`; handing back the bare entity means the transform
      // unwraps a property that is not there and the caller gets undefined.
      // The mock has to agree with the model, or it only ever simulates APIs
      // whose responses happen to be unwrapped.
      function envelope(data) {
        const restf = getprop(getprop(ctx.point, 'transform', {}), 'res')
        if (null == data || 'string' !== typeof restf) {
          return data
        }
        // Rebuild whatever nesting the op's response transform unwraps, so
        // the mock agrees with the model. Multi-segment on purpose: GraphQL
        // ops unwrap `body.data.<field>` (and `body.data.<field>.<entity>`
        // for mutation payloads), not just a single envelope property.
        const m = restf.match(/^`body\.(.+)`$/)
        if (null == m) {
          return data
        }
        let out = data
        const segs = m[1].split('.')
        for (let i = segs.length - 1; 0 <= i; i--) {
          out = { [segs[i]]: out }
        }
        return out
      }

      function respond(status, data, res) {
        const payload = envelope(data)
        const out = merge([
          {
            status,
            statusText: 'OK',
            json: async () => payload,
            body: 'not-used',
          },
          getdef(res, {})
        ])

        const headers = getprop(out, 'headers', {})

        // JS specific iterator.
        out.headers = {
          forEach(callback) {
            Object.keys(headers).forEach((key) => {
              callback(headers[key], key, this)
            })
          }
        }

        return out
      }


      const op = ctx.op
      const entmap = getprop(entity, op.entity, {})

      if ('load' === op.name) {
        const args = self.buildArgs(ctx, op, ctx.reqmatch)
        const found = select(entmap, args)
        const ent = getelem(found, 0)
        if (null == ent) {
          return respond(404, undefined, { statusText: S_NOT_FOUND })
        }
        else {
          delprop(ent, '$KEY')
          const out = clone(ent)
          return respond(200, out)
        }
      }
      else if ('list' === op.name) {
        const args = self.buildArgs(ctx, op, ctx.reqmatch)
        const found = select(entmap, args)
        if (null == found) {
          return respond(404, undefined, { statusText: S_NOT_FOUND })
        }
        else {
          found.map((ent) => delprop(ent, '$KEY'))
          const out = clone(found)
          return respond(200, out)
        }
      }
      else if ('update' === op.name) {
        const args = self.buildArgs(ctx, op, ctx.reqdata)
        const found = select(entmap, args)
        const ent = getelem(found, 0)
        if (null == ent) {
          return respond(404, undefined, { statusText: S_NOT_FOUND })
        }
        else {
          merge([ent, (ctx.reqdata || {})])
          delprop(ent, '$KEY')
          const out = clone(ent)
          return respond(200, out)
        }
      }
      else if ('remove' === op.name) {
        const args = self.buildArgs(ctx, op, ctx.reqmatch)
        const found = select(entmap, args)
        const ent = getelem(found, 0)
        if (null == ent) {
          return respond(404, undefined, { statusText: S_NOT_FOUND })
        }
        else {
          delprop(entmap, getprop(ent, 'id'))
          return respond(200)
        }
      }
      else if ('create' === op.name) {
        const args = self.buildArgs(ctx, op, ctx.reqdata)
        let id = param(ctx, 'id')
        if (null == id) {
          id = ((1e4 * Math.random() | 0).toString(16) +
            (1e4 * Math.random() | 0).toString(16) +
            (1e4 * Math.random() | 0).toString(16) +
            (1e4 * Math.random() | 0).toString(16)).padEnd(16, '0')
        }

        const ent = clone(ctx.reqdata)
        setprop(ent, 'id', id)
        setprop(entmap, id, ent)
        delprop(ent, '$KEY')
        const out = clone(ent)
        return respond(200, out)
      }
    }

    // Optional network behaviour simulation over the mock transport. Enable
    // per test via `SDK.test({ net: { latency, failTimes, ... } })`. When
    // `net` is absent the mock behaves exactly as before (no wrapping), so
    // existing generated tests are unaffected.
    const net = this._options.net
    ctx.utility.fetcher = (null == net) ? testFetcher : this.makeNetsim(net, testFetcher)
  }


  // Wrap a transport with simulated network conditions: latency (fixed or
  // {min,max}), a budget of first-N failures (`failTimes` -> `failStatus`),
  // first-N connection errors (`errorTimes`), or a hard `offline` outage.
  // Counter-driven, so simulations are deterministic across a test.
  makeNetsim(net, inner) {
    const self = this
    self._netcalls = 0

    function pickLatency() {
      const l = net.latency
      if (null == l) { return 0 }
      if ('number' === typeof l) { return l < 0 ? 0 : l }
      const min = l.min | 0
      const max = null == l.max ? min : l.max | 0
      return max <= min ? min : min + ((max - min) >> 1)
    }

    function sleep(ms) {
      if (null == ms || 0 >= ms) { return Promise.resolve() }
      if ('function' === typeof net.sleep) { return Promise.resolve(net.sleep(ms)) }
      return new Promise((r) => setTimeout(r, ms))
    }

    return async function netsimFetcher(ctx, url, fetchdef) {
      self._netcalls++
      const call = self._netcalls

      if (true === net.offline) {
        await sleep(pickLatency())
        return ctx.error('netsim_offline', 'Simulated network offline (URL was: "' + url + '")')
      }
      if (call <= (net.errorTimes | 0)) {
        await sleep(pickLatency())
        return ctx.error('netsim_conn', 'Simulated connection error (call ' + call + ')')
      }
      if (call <= (net.failTimes | 0)) {
        await sleep(pickLatency())
        const status = null == net.failStatus ? 503 : net.failStatus
        return {
          status,
          statusText: 'Simulated Failure',
          body: 'not-used',
          json: async () => undefined,
          headers: { forEach(_cb) { }, get(_k) { return undefined } },
        }
      }
      await sleep(pickLatency())
      return inner(ctx, url, fetchdef)
    }
  }


  buildArgs(ctx, op, args) {
    const struct = ctx.utility.struct
    const param = ctx.utility.param

    const getprop = struct.getprop
    const keysof = struct.keysof
    const getpath = struct.getpath
    const getelem = struct.getelem
    const select = struct.select
    const transform = struct.transform
    const isempty = struct.isempty

    const opname = getprop(op, 'name')
    const point =
      getelem(getpath(ctx.config, [
        'entity', getprop(ctx.entity, 'name'), 'op', opname, 'points']), -1)

    const reqd = transform(
      select(getpath(point, ['args', 'params']), { reqd: true }),
      ['`$EACH`', '', '`$KEY.name`']
    )

    const qand = []
    const q = { '`$AND`': qand }

    for (let k of keysof(args)) {
      if ('id' === k || !isempty(select(reqd, k))) {
        const v = param(ctx, k)
        const ka = getprop(op.alias, k)

        let qor = [{ [k]: v }]
        if (null != ka) {
          qor.push({ [ka]: v })
        }

        qor = { '`$OR`': qor }

        qand.push(qor)
      }
    }

    if (ctx.ctrl.explain) {
      ctx.ctrl.explain.test = { query: q }
    }

    return q
  }
}


module.exports = {
  TestFeature
}
