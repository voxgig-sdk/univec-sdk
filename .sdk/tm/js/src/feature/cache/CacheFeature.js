

const { BaseFeature } = require('../base/BaseFeature')


// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the
// same method+URL was fetched within `ttl` ms. Only successful responses to
// cacheable methods (default: GET) are stored, keyed by method+URL. The
// cache is bounded (`max` entries, oldest evicted) and every hit/miss is
// recorded on `client._cache` for inspection. One-shot response bodies are
// normalised on capture so both the current caller and later hits can read
// the JSON body repeatedly.
class CacheFeature extends BaseFeature {
  version = '0.0.1'
  name = 'cache'
  active = true

  _client
  _options = {}
  _store = new Map()


  init(ctx, options) {
    this._client = ctx.client
    this._options = options || {}
    this.active = options.active

    if (!this.active) {
      return
    }

    this._store = new Map()

    const self = this
    const utility = ctx.utility
    const inner = utility.fetcher

    utility.fetcher = async function (ctx2, url, fetchdef) {
      return self._through(ctx2, url, fetchdef, inner)
    }
  }


  async _through(ctx, url, fetchdef, inner) {
    const method = ((fetchdef && fetchdef.method) || 'GET').toUpperCase()
    const methods = this._options.methods || ['GET']

    if (methods.indexOf(method) < 0) {
      return inner(ctx, url, fetchdef)
    }

    const key = method + ' ' + url
    const now = this._now()
    const hit = this._store.get(key)

    if (null != hit && hit.expiry > now) {
      this._track('hit')
      return this._replay(hit.snapshot)
    }

    const res = await inner(ctx, url, fetchdef)

    if (this._cacheable(res)) {
      const snapshot = await this._snapshot(res)
      const ttl = null == this._options.ttl ? 5000 : this._options.ttl
      this._evict()
      this._store.set(key, { expiry: now + ttl, snapshot })
      this._track('miss')
      return this._replay(snapshot)
    }

    this._track('bypass')
    return res
  }


  _cacheable(res) {
    if (null == res || res instanceof Error) {
      return false
    }
    const status = res.status
    return 'number' === typeof status && status >= 200 && status < 300
  }


  async _snapshot(res) {
    let data = undefined
    if ('function' === typeof res.json) {
      try { data = await res.json() } catch (_e) { data = undefined }
    }
    const headers = {}
    if (res.headers && 'function' === typeof res.headers.forEach) {
      res.headers.forEach((v, k) => headers[k] = v)
    }
    return { status: res.status, statusText: res.statusText, data, headers }
  }


  _replay(snapshot) {
    const headers = snapshot.headers || {}
    return {
      status: snapshot.status,
      statusText: snapshot.statusText,
      body: 'not-used',
      json: async () => snapshot.data,
      headers: {
        get(key) { return headers[String(key).toLowerCase()] },
        forEach(callback) {
          Object.keys(headers).forEach((k) => callback(headers[k], k, this))
        },
      },
    }
  }


  _evict() {
    const max = null == this._options.max ? 256 : this._options.max
    while (this._store.size >= max) {
      const oldest = this._store.keys().next().value
      if (null == oldest) {
        break
      }
      this._store.delete(oldest)
    }
  }


  _now() {
    const now = this._options.now
    if ('function' === typeof now) {
      return now()
    }
    return Date.now()
  }


  _track(kind) {
    const client = this._client
    if (null == client._cache) {
      client._cache = { hit: 0, miss: 0, bypass: 0 }
    }
    client._cache[kind]++
  }
}


module.exports = {
  CacheFeature
}
