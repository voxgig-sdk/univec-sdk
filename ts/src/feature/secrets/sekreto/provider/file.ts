// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/file.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { Provider, SekretoError, envkey, nodemod } from './support'

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
