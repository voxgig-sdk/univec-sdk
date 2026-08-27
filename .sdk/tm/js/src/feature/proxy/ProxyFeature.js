

const { BaseFeature } = require('../base/BaseFeature')


// Outbound HTTP(S) proxy support. Wraps the active transport and attaches
// proxy routing to each request's fetch definition. The proxy target comes
// from options (`url`) or, when `fromEnv` is set, the standard
// HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. Constructing a
// concrete agent/dispatcher is dependency-specific, so a factory may be
// supplied via `options.agent` (e.g. wrapping undici's ProxyAgent); when
// absent the request is annotated with `fetchdef.proxy` for the transport
// to honour. Hosts matching `noProxy` bypass the proxy.
class ProxyFeature extends BaseFeature {
  version = '0.0.1'
  name = 'proxy'
  active = true

  _client
  _options = {}
  _url
  _noProxy = []


  init(ctx, options) {
    this._client = ctx.client
    this._options = options || {}
    this.active = options.active

    if (!this.active) {
      return
    }

    this._url = this._options.url
    let noProxy = this._options.noProxy

    if (true === this._options.fromEnv && 'undefined' !== typeof process && process.env) {
      this._url = this._url || process.env.HTTPS_PROXY || process.env.https_proxy ||
        process.env.HTTP_PROXY || process.env.http_proxy
      noProxy = noProxy || process.env.NO_PROXY || process.env.no_proxy
    }

    this._noProxy = ('string' === typeof noProxy ? noProxy.split(/\s*,\s*/) : (noProxy || []))
      .filter((s) => null != s && '' !== s)

    const self = this
    const utility = ctx.utility
    const inner = utility.fetcher

    utility.fetcher = async function (ctx2, url, fetchdef) {
      fetchdef = self._route(url, fetchdef)
      return inner(ctx2, url, fetchdef)
    }
  }


  _route(url, fetchdef) {
    if (null == this._url || this._bypass(url)) {
      return fetchdef
    }

    const out = { ...fetchdef, proxy: this._url }

    const agent = this._options.agent
    if ('function' === typeof agent) {
      // Factory returns a transport-specific agent/dispatcher.
      const made = agent(this._url, url)
      out.dispatcher = made
      out.agent = made
    }

    this._track(url)
    return out
  }


  _bypass(url) {
    if (0 === this._noProxy.length) {
      return false
    }
    let host = url
    const m = /^[a-z]+:\/\/([^/:]+)/i.exec(url)
    if (m) {
      host = m[1]
    }
    for (const np of this._noProxy) {
      if ('*' === np) {
        return true
      }
      if (host === np || host.endsWith('.' + np.replace(/^\./, ''))) {
        return true
      }
    }
    return false
  }


  _track(url) {
    const client = this._client
    if (null == client._proxy) {
      client._proxy = { routed: 0, url: this._url }
    }
    client._proxy.routed++
  }
}


module.exports = {
  ProxyFeature
}
