// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/secretspec.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import {
  ProviderSpec, Provider, SekretoError, envkey, nodemod, providerplugin,
} from '../provider/support'

/** SecretSpec — https://secretspec.dev
 *
 * A declaration plus a chain of its own backends: the same shape as
 * sekreto one level down. A project that has declared its secrets there
 * should not have to declare them again here, so this reads through the
 * `secretspec` CLI rather than reimplementing its resolution.
 *
 * SecretSpec audits every read and refuses without `--reason`; sekreto
 * sends `sekreto` unless configured otherwise. */
export function secretspecprovider(options?: {
  command?: string
  file?: string
  profile?: string
  backend?: string
  reason?: string
  prefix?: string
}): Provider {
  const opts = options || {}
  const command = opts.command || 'secretspec'

  return {
    lookup: (name: string) => {
      const key = envkey(name, opts.prefix)

      const args: string[] = []
      if (opts.file) {
        args.push('--file', opts.file)
      }
      args.push('get', key)
      if (opts.backend) {
        args.push('--provider', opts.backend)
      }
      if (opts.profile) {
        args.push('--profile', opts.profile)
      }
      args.push('--reason', opts.reason || 'sekreto')

      const { spawnSync } = nodemod<typeof import('node:child_process')>('node:child_process')
      const run = spawnSync(command, args, { encoding: 'utf8' })

      if (run.error) {
        throw new SekretoError('sekreto: cannot run ' + command + ': ' + run.error.message)
      }

      if (0 === run.status) {
        // The value and one newline, and nothing else.
        return run.stdout.replace(/\n$/, '')
      }

      const why = (run.stderr || '').trim()

      if (secretspecmiss(why, key)) {
        return undefined
      }

      throw new SekretoError('sekreto: secretspec error: ' + (why || 'exit ' + run.status))
    },
    describe: () => 'secretspec' + (opts.backend ? ':' + opts.backend : ''),
  }
}

/** Does this SecretSpec failure mean "no such secret" rather than "I
 * could not answer"?
 *
 * SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
 * not declare and one declared with no value, and both are misses: this
 * store does not hold it, so the chain carries on.
 *
 * MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
 * `Provider backend 'keyring' not found`, which is a store that could
 * not answer at all - and reading that as a miss is the worst failure
 * this library has, because the chain then falls through to a weaker
 * store without saying so. The key is required to appear, so the two
 * cannot be confused. */
function secretspecmiss(why: string, key: string): boolean {
  return why.includes("Secret '" + key + "' not found")
}

/** The plugin. Needs a child process. */
export const secretspec = providerplugin('secretspec', (spec: ProviderSpec) =>
  secretspecprovider({
    command: spec.command,
    file: spec.file,
    profile: spec.profile,
    backend: spec.backend,
    reason: spec.reason,
    prefix: spec.prefix,
  }),
)
