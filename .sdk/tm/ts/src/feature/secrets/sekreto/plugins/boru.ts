// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/boru.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import {
  ProviderSpec, Provider, SekretoError, checkname, nodemod, providerplugin,
} from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

/** A boru vault (https://github.com/boru-lang/boru).
 *
 * Two ways in, both boru's own.
 *
 * With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
 * secret on stdout and nothing else. The passphrase is read by boru
 * itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as
 * config and never puts it on a command line, where it would show up in
 * the process table.
 *
 * With an `addr`, boru's wire protocol: `boru vault serve` publishes a
 * read-only, HashiCorp-shaped provision API (boru's
 * design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
 * from `boru vault grant`. A sekreto name is already a valid boru
 * alias, and boru aliases keep their dots, so `api.token` is the single
 * path segment `api.token` - not the `api`/`token` split a HashiCorp KV
 * gets. The value is the `value` field. A 404 is a miss; anything else
 * the server refuses (a revoked capability, a sealed vault) is an
 * error.
 *
 * boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
 * credential *broker*, built precisely so the caller never receives the
 * credential. `vault serve` is the provision endpoint, built to hand
 * the value back - that is the one sekreto uses. */
export function boruprovider(options?: {
  command?: string
  namespace?: string
  home?: string
  addr?: string
  token?: string
  mount?: string
}): Provider {
  const opts = options || {}
  const command = opts.command || 'boru'

  if (opts.addr) {
    const addr = opts.addr.replace(/\/$/, '')
    const mount = opts.mount || 'secret'

    return {
      lookup: async (name: string) => {
        checkname(name)
        checkaddr(addr)

        const alias = opts.namespace ? opts.namespace + '/' + name : name
        const url = addr + '/v1/' + mount + '/data/' + alias

        const res = await fetchjson('GET', url, { 'X-Vault-Token': opts.token || '' })

        if (404 === res.status) {
          return undefined
        }

        if (200 !== res.status) {
          throw new SekretoError('sekreto: boru serve error: ' + res.status + ': ' + url)
        }

        const data = res.body && res.body.data && res.body.data.data
        const value = data ? data['value'] : undefined
        return undefined === value || null === value ? undefined : String(value)
      },
      describe: () => 'boru:' + addr,
    }
  }

  return {
    lookup: (name: string) => {
      checkname(name)

      const alias = opts.namespace ? opts.namespace + ':' + name : name
      const env = opts.home ? { ...process.env, BORU_HOME: opts.home } : process.env

      const { spawnSync } = nodemod<typeof import('node:child_process')>('node:child_process')
      const run = spawnSync(command, ['vault', 'get', '--reveal', alias], {
        encoding: 'utf8',
        env,
      })

      if (run.error) {
        throw new SekretoError('sekreto: cannot run ' + command + ': ' + run.error.message)
      }

      if (0 === run.status) {
        // boru prints the value and one newline, and nothing else.
        return run.stdout.replace(/\n$/, '')
      }

      const why = (run.stderr || '').trim()

      // "no alias named" is boru saying it does not hold this secret, which
      // is a miss: the chain carries on to the next provider. A locked vault
      // or a wrong passphrase is not a miss - treating it as one would fall
      // through to a weaker store without saying so.
      if (borumiss(why)) {
        return undefined
      }

      throw new SekretoError('sekreto: boru vault error: ' + (why || 'exit ' + run.status))
    },
    describe: () => 'boru' + (opts.namespace ? ':' + opts.namespace : ''),
  }
}

/** Does this boru failure mean "no such secret" rather than "I could not
 * answer"? Matched on boru's own wording for a missing alias. */
function borumiss(why: string): boolean {
  return /no alias named/.test(why)
}


/** The plugin. Needs a child process (CLI mode) or HTTPS (wire mode). */
export const boru = providerplugin('boru', (spec: ProviderSpec) =>
  boruprovider({
    command: spec.command,
    namespace: spec.namespace,
    home: spec.home,
    addr: spec.addr,
    token: spec.token,
    mount: spec.mount,
  }),
)
