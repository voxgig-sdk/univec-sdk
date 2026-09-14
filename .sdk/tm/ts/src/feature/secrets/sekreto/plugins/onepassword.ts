// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/onepassword.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import {
  ProviderSpec, Provider, SekretoError, checkname, providerplugin,
} from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

/** 1Password, through a Connect server.
 *
 * The item titled `api.token` (titles keep their dots), in the named
 * vault. The value is the field with purpose PASSWORD, or the field
 * labelled `value`. A vault that cannot be found is an error - config
 * names it, so its absence is a broken store, not a missing secret. */
export function onepasswordprovider(options?: {
  addr?: string
  token?: string
  vault?: string
}): Provider {
  const opts = options || {}

  let vaultid: string | undefined

  const auth = (): Record<string, string> => ({
    authorization: 'Bearer ' + (opts.token || ''),
  })

  const resolvevault = async (addr: string): Promise<string> => {
    const want = opts.vault || ''
    if ('' === want) {
      throw new SekretoError('sekreto: onepassword: no vault')
    }

    const res = await fetchjson('GET', addr + '/v1/vaults', auth())

    if (200 !== res.status || !Array.isArray(res.body)) {
      throw new SekretoError('sekreto: onepassword error: ' + res.status + ': listing vaults')
    }

    for (const entry of res.body) {
      if (entry && (want === entry.id || want === entry.name)) {
        return String(entry.id)
      }
    }

    throw new SekretoError('sekreto: onepassword: no vault named ' + want)
  }

  return {
    lookup: async (name: string) => {
      checkname(name)

      const addr = (opts.addr || '').replace(/\/$/, '')
      if ('' === addr) {
        throw new SekretoError('sekreto: onepassword: no addr')
      }
      checkaddr(addr)

      if (undefined === vaultid) {
        vaultid = await resolvevault(addr)
      }

      const filter = encodeURIComponent('title eq "' + name + '"')
      const found = await fetchjson(
        'GET',
        addr + '/v1/vaults/' + vaultid + '/items?filter=' + filter,
        auth(),
      )

      if (200 !== found.status || !Array.isArray(found.body)) {
        throw new SekretoError('sekreto: onepassword error: ' + found.status + ': finding ' + name)
      }

      if (0 === found.body.length) {
        return undefined
      }

      const item = await fetchjson(
        'GET',
        addr + '/v1/vaults/' + vaultid + '/items/' + found.body[0].id,
        auth(),
      )

      if (200 !== item.status) {
        throw new SekretoError('sekreto: onepassword error: ' + item.status + ': reading ' + name)
      }

      const fields = (item.body && item.body.fields) || []

      for (const field of fields) {
        if (field && 'PASSWORD' === field.purpose) {
          return undefined === field.value || null === field.value ? undefined : String(field.value)
        }
      }
      for (const field of fields) {
        if (field && 'value' === field.label) {
          return undefined === field.value || null === field.value ? undefined : String(field.value)
        }
      }

      return undefined
    },
    describe: () => 'onepassword:' + (opts.vault || ''),
  }
}


/** The plugin. Needs HTTPS. */
export const onepassword = providerplugin('onepassword', (spec: ProviderSpec) =>
  onepasswordprovider(spec))
