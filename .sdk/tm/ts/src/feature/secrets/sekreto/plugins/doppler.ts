// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/doppler.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { ProviderSpec, Provider, SekretoError, envkey, providerplugin } from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

/** Doppler.
 *
 * The whole config is downloaded once - Doppler's own bulk endpoint -
 * and answered from memory, like a remote .env: `api.token` is the
 * `API_TOKEN` entry. A service token is config-scoped, so project and
 * config are only needed with broader tokens. */
export function dopplerprovider(options?: {
  token?: string
  project?: string
  config?: string
  addr?: string
}): Provider {
  const opts = options || {}

  let values: Record<string, string> | undefined

  const load = async (): Promise<Record<string, string>> => {
    if (undefined !== values) {
      return values
    }

    const addr = (opts.addr || 'https://api.doppler.com').replace(/\/$/, '')
    checkaddr(addr)

    let url = addr + '/v3/configs/config/secrets/download?format=json'
    if (opts.project) {
      url += '&project=' + encodeURIComponent(opts.project)
    }
    if (opts.config) {
      url += '&config=' + encodeURIComponent(opts.config)
    }

    const res = await fetchjson('GET', url, {
      authorization: 'Bearer ' + (opts.token || ''),
    })

    if (200 !== res.status || !res.body || 'object' !== typeof res.body) {
      throw new SekretoError('sekreto: doppler error: ' + res.status)
    }

    values = {}
    for (const [key, value] of Object.entries(res.body)) {
      if (null !== value && undefined !== value) {
        values[key] = String(value)
      }
    }

    return values
  }

  return {
    lookup: async (name: string) => (await load())[envkey(name)],
    describe: () =>
      'doppler' + (opts.project ? ':' + opts.project + '/' + (opts.config || '') : ''),
  }
}


/** The plugin. Needs HTTPS. */
export const doppler = providerplugin('doppler', (spec: ProviderSpec) =>
  dopplerprovider(spec))
