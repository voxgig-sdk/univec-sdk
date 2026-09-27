// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/boru.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import {
  ProviderSpec, Provider, SekretoError, checkname, nodemod, providerplugin,
} from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

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
