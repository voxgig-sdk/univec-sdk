// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/support.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { PluginError } from '../../plugin'
import type { Definition } from '../../plugin'

import {
  SekretoError,
  awsparam,
  checkname,
  envkey,
  flatname,
  parsedotenv,
  vaultref,
} from '../Sekreto'

const nodemods: Record<string, any> = {}

function nodemod<T = any>(name: string): T {
  let mod = nodemods[name]

  if (undefined === mod) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      mod = nodemods[name] = require(name)
    } catch (err: any) {
      throw new SekretoError(
        'sekreto: this provider needs ' +
          name +
          ', which this runtime does not provide: ' +
          err.message,
      )
    }
  }

  return mod as T
}

export type Provider = {
  lookup: (name: string) => Promise<string | undefined> | string | undefined
  describe: () => string
}

/** The declarative form of a provider, as used in config and in the
 * shared spec. `kind` names a built-in or a plugin; the rest is that
 * kind's own configuration, and a plugin reads it as `inst.options`. */
export type ProviderSpec = {
  kind: string
  name?: string
  prefix?: string
  file?: string
  values?: Record<string, string>
  dir?: string
  addr?: string
  token?: string
  mount?: string
  kv?: number
  vaultnamespace?: string
  /** hashicorp: log in for a token instead of being handed one. */
  auth?: {
    method: 'kubernetes' | 'approle'
    mount?: string
    role?: string
    jwt?: string
    jwtfile?: string
    roleid?: string
    secretid?: string
  }
  command?: string
  profile?: string
  backend?: string
  reason?: string
  namespace?: string
  home?: string
  region?: string
  keyid?: string
  secret?: string
  session?: string
  project?: string
  vault?: string
  tenant?: string
  clientid?: string
  clientsecret?: string
  /** azure: where to log in / where IMDS answers. gcp: where the
   * metadata server answers. Overridable for tests and for clouds with
   * nonstandard endpoints. */
  loginaddr?: string
  imdsaddr?: string
  metadataaddr?: string
  apiversion?: string
  config?: string
  environment?: string
  path?: string
  passphrase?: string
  /** minivault: which key in the vault file to open with, defaulting to
   * `master`. Named apart from `key` and `keyid` because those already
   * mean a secret name and an AWS access key id. */
  vaultkey?: string
  iterations?: number
  create?: boolean
}


/** The export key under which a provider definition publishes the
 * provider it built. `Sekreto` reads `<ref>/provider` off the host. */
export const PROVIDER_EXPORT = 'provider'

export const ERROR_CODE = 'sekreto_error'

export function providerplugin(
  kind: string,
  make: (spec: ProviderSpec) => Provider,
): Definition {
  return {
    name: kind,
    define: (inst: any) => {
      let provider: Provider
      try {
        provider = make(inst.options as ProviderSpec)
      } catch (err: any) {
        if (err instanceof SekretoError) {
          throw new PluginError(ERROR_CODE, err.message, { ref: inst.ref, cause: err.message })
        }
        throw err
      }
      inst.export(PROVIDER_EXPORT, provider)
    },
  }
}

export {
  SekretoError, awsparam, checkname, envkey, flatname, parsedotenv, vaultref,
}
export { nodemod }
export type { Definition }

export function unbase64(text: string): string | undefined {
  const trimmed = text.replace(/\s+/g, '')

  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(trimmed) || 0 !== trimmed.length % 4) {
    return undefined
  }

  return Buffer.from(trimmed, 'base64').toString('utf8')
}
