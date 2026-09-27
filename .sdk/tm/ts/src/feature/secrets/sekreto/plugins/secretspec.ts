// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/secretspec.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import {
  ProviderSpec, Provider, SekretoError, envkey, nodemod, providerplugin,
} from '../provider/support'

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
