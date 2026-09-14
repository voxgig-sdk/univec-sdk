// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/hashicorp.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import {
  ProviderSpec, Provider, SekretoError, nodemod, providerplugin, vaultref,
} from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

/** HashiCorp Vault.
 *
 * KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
 * and takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
 * `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means
 * "not here" - a miss - so a vault can sit in a chain with fallbacks.
 *
 * A Vault Enterprise namespace rides the X-Vault-Namespace header, on
 * logins as well as reads.
 *
 * Instead of being handed a token, the provider can log in: Kubernetes
 * auth (the pod's service-account JWT, from its conventional path) or
 * AppRole. A failed login is an error, never a miss - it means this
 * store could not answer at all. */
export function hashicorpprovider(
  addr: string,
  token: string,
  options?: {
    mount?: string
    kv?: number
    vaultnamespace?: string
    auth?: ProviderSpec['auth']
  },
): Provider {
  const opts = options || {}
  const usemount = opts.mount || 'secret'
  const kv = opts.kv || 2

  // A version typo like kv: 3 must not quietly behave as v2 and turn
  // its 404s into misses; there is nothing safe to assume it meant.
  if (1 !== kv && 2 !== kv) {
    throw new SekretoError('sekreto: hashicorp: unsupported kv version: ' + String(kv))
  }

  // The working token: a configured token is kept forever, a logged-in
  // token is renewed shortly before its lease runs out - a long-running
  // process must not keep presenting a token the vault already expired.
  let livetoken: string | undefined = '' === token ? undefined : token
  let renewat = Infinity

  const baseheaders = (): Record<string, string> => {
    const headers: Record<string, string> = {}
    if (opts.vaultnamespace) {
      headers['X-Vault-Namespace'] = opts.vaultnamespace
    }
    return headers
  }

  const login = async (): Promise<string> => {
    const auth = opts.auth
    if (!auth) {
      throw new SekretoError('sekreto: hashicorp: no token and no auth method')
    }

    const mount = auth.mount || auth.method
    const url = addr.replace(/\/$/, '') + '/v1/auth/' + mount + '/login'

    let body: any
    if ('kubernetes' === auth.method) {
      let jwt = auth.jwt
      if (undefined === jwt) {
        const file = auth.jwtfile || '/var/run/secrets/kubernetes.io/serviceaccount/token'
        try {
          const { readFileSync } = nodemod<typeof import('node:fs')>('node:fs')
          jwt = readFileSync(file, 'utf8').trim()
        } catch (err: any) {
          throw new SekretoError('sekreto: hashicorp: cannot read jwt file ' + file)
        }
      }
      body = { role: auth.role || '', jwt }
    } else if ('approle' === auth.method) {
      body = { role_id: auth.roleid || '', secret_id: auth.secretid || '' }
    } else {
      throw new SekretoError('sekreto: hashicorp: unknown auth method: ' + String(auth.method))
    }

    const res = await fetchjson('POST', url, baseheaders(), JSON.stringify(body))

    const got = res.body && res.body.auth && res.body.auth.client_token
    if (200 !== res.status || !got) {
      throw new SekretoError('sekreto: hashicorp login failed: ' + res.status + ': ' + url)
    }

    const lease = Number(res.body.auth.lease_duration)
    renewat = 0 < lease ? Date.now() + Math.max(lease - 60, 1) * 1000 : Infinity

    return String(got)
  }

  return {
    lookup: async (name: string) => {
      checkaddr(addr)

      if (undefined === livetoken || Date.now() >= renewat) {
        livetoken = await login()
      }

      const ref = vaultref(name)
      const base = addr.replace(/\/$/, '') + '/v1/' + usemount
      const url = 1 === kv ? base + '/' + ref.path : base + '/data/' + ref.path

      const headers = baseheaders()
      headers['X-Vault-Token'] = livetoken

      const res = await fetchjson('GET', url, headers)

      if (404 === res.status) {
        return undefined
      }

      if (200 !== res.status) {
        throw new SekretoError('sekreto: hashicorp error: ' + res.status + ': ' + url)
      }

      const data =
        1 === kv ? res.body && res.body.data : res.body && res.body.data && res.body.data.data

      const value = data ? data[ref.field] : undefined
      return undefined === value || null === value ? undefined : String(value)
    },
    describe: () => 'hashicorp:' + addr + '/' + usemount,
  }
}


/** The plugin. Needs HTTPS, and the filesystem for a kubernetes JWT. */
export const hashicorp = providerplugin('hashicorp', (spec: ProviderSpec) =>
  hashicorpprovider(spec.addr || '', spec.token || '', {
    mount: spec.mount,
    kv: spec.kv,
    vaultnamespace: spec.vaultnamespace,
    auth: spec.auth,
  }),
)
