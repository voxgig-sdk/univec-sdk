// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/file.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { Provider, SekretoError, envkey, nodemod } from './support'

/** A directory of one-secret-per-file entries, keyed like the
 * environment: `api.token` reads `<dir>/API_TOKEN`.
 *
 * This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
 * secret, and a systemd credentials directory, so those all work with no
 * further configuration. One trailing newline is stripped - tools that
 * write these files disagree about it, and a newline is never part of a
 * secret on purpose. */
export function fileprovider(dir: string, prefix?: string): Provider {
  return {
    lookup: (name: string) => {
      const { join } = nodemod<typeof import('node:path')>('node:path')
      const file = join(dir, envkey(name, prefix))

      let text: string
      try {
        const { readFileSync } = nodemod<typeof import('node:fs')>('node:fs')
        text = readFileSync(file, 'utf8')
      } catch (err: any) {
        // An absent file - or an absent directory - means "no secrets
        // here", exactly like a missing .env. Anything else (permission
        // denied, an unreadable mount) is a store that could not answer.
        if ('ENOENT' === err.code || 'ENOTDIR' === err.code) {
          return undefined
        }
        throw new SekretoError('sekreto: file provider cannot read ' + file + ': ' + err.message)
      }

      return text.replace(/\r?\n$/, '')
    },
    describe: () => 'file:' + dir,
  }
}
