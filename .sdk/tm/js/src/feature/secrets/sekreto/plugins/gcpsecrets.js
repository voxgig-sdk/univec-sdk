// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/plugins/gcpsecrets.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// A port of typescript/plugins/gcpsecrets.ts, which is canonical.

const {
  SekretoError, flatname, providerplugin, unbase64,
} = require('../provider/support')
const { checkaddr } = require('../provider/addr')
const { fetchjson } = require('./httpjson')

/** GCP Secret Manager.
 *
 * `api.token` reads secret `api_token` (dots flattened to `_`; Secret
 * Manager ids have no hierarchy and reject dots), latest version. The
 * token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
 * GCE/GKE metadata server - so on Google's own platform no credential
 * configuration is needed at all.
 *
 * The metadata call itself is plain http to a link-local host by
 * platform design; no credential rides on it, so `checkaddr` guards the
 * Secret Manager address instead. */
function gcpsecretsprovider(options) {
  const opts = options || {}

  // A configured token is kept forever; a metadata-server token carries
  // expires_in and is renewed shortly before it runs out.
  let livetoken
  let renewat = Infinity

  const metadataaddr = () => {
    if (opts.metadataaddr) {
      return opts.metadataaddr
    }
    const host = process.env.GCE_METADATA_HOST
    return host ? 'http://' + host : 'http://metadata.google.internal'
  }

  const login = async () => {
    const configured = opts.token || process.env.GOOGLE_OAUTH_ACCESS_TOKEN
    if (configured) {
      return configured
    }

    const url =
      metadataaddr().replace(/\/$/, '') +
      '/computeMetadata/v1/instance/service-accounts/default/token'

    const res = await fetchjson('GET', url, { 'Metadata-Flavor': 'Google' })

    const got = res.body && res.body.access_token
    if (200 !== res.status || !got) {
      throw new SekretoError('sekreto: gcp: no token and metadata server did not answer')
    }

    const expires = Number(res.body.expires_in)
    renewat = 0 < expires ? Date.now() + Math.max(expires - 60, 1) * 1000 : Infinity

    return String(got)
  }

  return {
    lookup: async (name) => {
      const project = opts.project || ''
      if ('' === project) {
        throw new SekretoError('sekreto: gcp: no project')
      }

      const addr = opts.addr || 'https://secretmanager.googleapis.com'
      checkaddr(addr)

      if (undefined === livetoken || Date.now() >= renewat) {
        livetoken = await login()
      }

      const url =
        addr.replace(/\/$/, '') +
        '/v1/projects/' +
        project +
        '/secrets/' +
        flatname(name, '_') +
        '/versions/latest:access'

      const res = await fetchjson('GET', url, { authorization: 'Bearer ' + livetoken })

      if (404 === res.status) {
        return undefined
      }

      if (200 !== res.status) {
        throw new SekretoError('sekreto: gcp error: ' + res.status + ': ' + url)
      }

      const data = res.body && res.body.payload && res.body.payload.data
      if ('string' !== typeof data) {
        return undefined
      }

      const decoded = unbase64(data)
      if (undefined === decoded) {
        throw new SekretoError('sekreto: gcp: undecodable secret')
      }

      return decoded
    },
    describe: () => 'gcpsecrets:' + (opts.project || ''),
  }
}

/** The plugin. Needs HTTPS. */
const gcpsecrets = providerplugin('gcpsecrets', (spec) => gcpsecretsprovider(spec))

module.exports = { gcpsecrets, gcpsecretsprovider }
