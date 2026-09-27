// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/infisical.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { ProviderSpec, Provider, SekretoError, envkey, providerplugin } from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

export function infisicalprovider(options?: {
  addr?: string
  token?: string
  clientid?: string
  clientsecret?: string
  project?: string
  environment?: string
  path?: string
}): Provider {
  const opts = options || {}

  // A configured token is kept forever; a universal-auth token carries
  // expiresIn and is renewed shortly before it runs out.
  let livetoken: string | undefined
  let renewat = Infinity

  const login = async (addr: string): Promise<string> => {
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
    lookup: async (name: string) => {
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
export const infisical = providerplugin('infisical', (spec: ProviderSpec) =>
  infisicalprovider(spec))
