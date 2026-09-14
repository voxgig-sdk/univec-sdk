// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/plugins/infisical.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// A port of typescript/plugins/infisical.ts, which is canonical.

const { SekretoError, envkey, providerplugin } = require('../provider/support')
const { checkaddr } = require('../provider/addr')
const { fetchjson } = require('./httpjson')

/** Infisical.
 *
 * `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
 * convention is environment-style keys) at a secret path in one
 * environment of a project. Auth is a token, or a universal-auth
 * (machine identity) login with clientid/clientsecret. */
function infisicalprovider(options) {
  const opts = options || {}

  // A configured token is kept forever; a universal-auth token carries
  // expiresIn and is renewed shortly before it runs out.
  let livetoken
  let renewat = Infinity

  const login = async (addr) => {
    if (opts.token) {
      return opts.token
    }

    if (!opts.clientid || !opts.clientsecret) {
      throw new SekretoError('sekreto: infisical: no token and no client credentials')
    }

    const res = await fetchjson(
      'POST',
      addr + '/api/v1/auth/universal-auth/login',
      { 'content-type': 'application/json' },
      JSON.stringify({ clientId: opts.clientid, clientSecret: opts.clientsecret }),
    )

    const got = res.body && res.body.accessToken
    if (200 !== res.status || !got) {
      throw new SekretoError('sekreto: infisical login failed: ' + res.status)
    }

    const expires = Number(res.body.expiresIn)
    renewat = 0 < expires ? Date.now() + Math.max(expires - 60, 1) * 1000 : Infinity

    return String(got)
  }

  return {
    lookup: async (name) => {
      const addr = (opts.addr || 'https://app.infisical.com').replace(/\/$/, '')
      checkaddr(addr)

      const project = opts.project || ''
      const environment = opts.environment || ''
      if ('' === project || '' === environment) {
        throw new SekretoError('sekreto: infisical: no project/environment')
      }

      if (undefined === livetoken || Date.now() >= renewat) {
        livetoken = await login(addr)
      }

      const url =
        addr +
        '/api/v3/secrets/raw/' +
        envkey(name) +
        '?workspaceId=' +
        encodeURIComponent(project) +
        '&environment=' +
        encodeURIComponent(environment) +
        '&secretPath=' +
        encodeURIComponent(opts.path || '/')

      const res = await fetchjson('GET', url, { authorization: 'Bearer ' + livetoken })

      if (404 === res.status) {
        return undefined
      }

      if (200 !== res.status) {
        throw new SekretoError('sekreto: infisical error: ' + res.status)
      }

      const value = res.body && res.body.secret && res.body.secret.secretValue
      return undefined === value || null === value ? undefined : String(value)
    },
    describe: () => 'infisical:' + (opts.project || '') + '/' + (opts.environment || ''),
  }
}

/** The plugin. Needs HTTPS. */
const infisical = providerplugin('infisical', (spec) => infisicalprovider(spec))

module.exports = { infisical, infisicalprovider }
