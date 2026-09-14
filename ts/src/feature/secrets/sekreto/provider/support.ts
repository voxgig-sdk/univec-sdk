// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/support.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// What a provider is, what its declarative form looks like, and how a
// provider kind becomes a voxgig/plugin definition.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or undefined to mean "ask the next one". Nothing else about
// a provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//
// Two failure shapes, and they are never interchangeable. A store that
// does not hold the secret is a MISS (undefined) - the chain carries on.
// A store that could not answer - bad credentials, unreachable host,
// missing configuration - is an ERROR: falling through there would
// quietly reach for a weaker store.

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

// NODE BUILTINS, LOADED ON FIRST USE.
//
// `fs` and `path` are what the two built-in file-reading providers need,
// and they are loaded when a lookup runs rather than when sekreto is
// imported: a caller who only ever configures `memory` or `env` never
// evaluates them, and a runtime that lacks them fails at the point of
// use rather than at import. The platform-dependent providers proper -
// everything that opens a socket or spawns a process - are not in the
// core at all; they are plugins (docs/design/plugin-providers.md).
//
// A plain require(), not `await import()`: dotenvprovider and
// fileprovider have SYNCHRONOUS lookups, and making them async to
// accommodate a dynamic import would change observable behaviour for
// anyone calling a provider directly. The package is CommonJS ("type":
// "commonjs"), so require is available and synchronous.
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
  /** The value, or undefined if this provider does not have it. */
  lookup: (name: string) => Promise<string | undefined> | string | undefined
  /** A short description, shown by `Sekreto.sources()`. */
  describe: () => string
}

/** The declarative form of a provider, as used in config and in the
 * shared spec. `kind` names a built-in or a plugin; the rest is that
 * kind's own configuration, and a plugin reads it as `inst.options`. */
export type ProviderSpec = {
  kind: string
  /** The store name `Sekreto.getfrom` addresses. Defaults to `kind`. */
  name?: string
  prefix?: string
  /** dotenv: the file to read. secretspec: the declaration file. */
  file?: string
  /** memory: literal values, keyed like environment variables. */
  values?: Record<string, string>
  /** file: the directory of one-secret-per-file entries. */
  dir?: string
  /** hashicorp / boru (wire) / gcp / 1password / doppler / infisical:
   * the base URL. */
  addr?: string
  /** hashicorp / boru (wire) / gcp / azure / 1password / doppler /
   * infisical: the access token. */
  token?: string
  /** hashicorp / boru (wire): the KV mount (default `secret`). */
  mount?: string
  /** hashicorp: KV engine version, 1 or 2 (default 2). */
  kv?: number
  /** hashicorp: Vault Enterprise namespace (X-Vault-Namespace). */
  vaultnamespace?: string
  /** hashicorp: log in for a token instead of being handed one. */
  auth?: {
    method: 'kubernetes' | 'approle'
    /** The auth mount, defaulting to the method name. */
    mount?: string
    /** kubernetes: the Vault role to log in as. */
    role?: string
    /** kubernetes: the service-account JWT itself (tests). */
    jwt?: string
    /** kubernetes: where the JWT lives; the conventional pod path by
     * default. */
    jwtfile?: string
    /** approle: the role and secret ids. */
    roleid?: string
    secretid?: string
  }
  /** boru / secretspec: the executable to run (default: the kind's own
   * name). */
  command?: string
  /** secretspec: the profile to read (`--profile`). */
  profile?: string
  /** secretspec: which of ITS backends to read from (`--provider`), e.g.
   * `keyring` or `dotenv://.env`. Named `backend` here because
   * `provider` already means a sekreto provider. */
  backend?: string
  /** secretspec: the audit reason recorded for the read (`--reason`).
   * SecretSpec refuses to read without one. */
  reason?: string
  /** boru: the namespace qualifying the alias. */
  namespace?: string
  /** boru: the vault home, passed as BORU_HOME. */
  home?: string
  /** aws: region and credentials; the standard AWS_* environment
   * variables fill whichever are not given. */
  region?: string
  keyid?: string
  secret?: string
  session?: string
  /** gcp / doppler / infisical: the project (GCP project id, Doppler
   * project slug, Infisical workspace id). */
  project?: string
  /** azure: the Key Vault name or full URL. 1password: the vault name
   * or id. */
  vault?: string
  /** azure: client-credential login. infisical: universal-auth login
   * (tenant is Azure-only). */
  tenant?: string
  clientid?: string
  clientsecret?: string
  /** azure: where to log in / where IMDS answers. gcp: where the
   * metadata server answers. Overridable for tests and for clouds with
   * nonstandard endpoints. */
  loginaddr?: string
  imdsaddr?: string
  metadataaddr?: string
  /** azure: the Key Vault API version (default 7.4). */
  apiversion?: string
  /** doppler: the config slug (with `project`). */
  config?: string
  /** infisical: the environment slug and secret path. */
  environment?: string
  path?: string
}

// --- providers as voxgig/plugin definitions --------------------------

/** The export key under which a provider definition publishes the
 * provider it built. `Sekreto` reads `<ref>/provider` off the host. */
export const PROVIDER_EXPORT = 'provider'

/** The voxgig/plugin error code a SekretoError travels under when it is
 * raised inside a definition's `define`.
 *
 * plugin wraps a code-less error raised by a callback as
 * `plugin_define_failed`, and keeps an error that already carries a
 * code. A provider that refuses its own configuration - `kv: 3`, a
 * missing project - raises a SekretoError, and that message is pinned
 * by the spec byte for byte, so it must come back out of the host
 * exactly as it went in. `providerplugin` gives it this code on the way
 * in; `Sekreto` turns it back into a SekretoError on the way out. */
export const ERROR_CODE = 'sekreto_error'

/** A provider kind, as a voxgig/plugin definition.
 *
 * This is the whole bridge between the two libraries. The definition's
 * `name` is the `kind` a ProviderSpec names; its `define` reads the spec
 * as `inst.options`, builds the provider with `make`, and exports it.
 * Nothing runs at `activate`: a provider opens nothing until its first
 * lookup, so there is nothing to capture - a provider that does hold a
 * resource acquires it there and lets the instance scope unwind it.
 *
 * Every built-in and every plugin is made this way, so a custom
 * provider kind is one call:
 *
 *     providerplugin('mystore', (spec) => mystoreprovider(spec.addr))
 */
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

/** Decode standard base64, or undefined when the text is not base64.
 *
 * `Buffer.from(text, 'base64')` is lenient: it skips anything outside the
 * alphabet and hands back whatever it managed, so a corrupted payload
 * became a plausible-looking string of bytes that the caller then returned
 * AS THE SECRET. The alphabet is checked first so that a store which
 * answered incoherently can be told apart from one that answered.
 *
 * A store that could not answer coherently is an ERROR, never a miss — the
 * same rule this code already applies to a 200 whose body is not JSON. */
export function unbase64(text: string): string | undefined {
  const trimmed = text.replace(/\s+/g, '')

  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(trimmed) || 0 !== trimmed.length % 4) {
    return undefined
  }

  return Buffer.from(trimmed, 'base64').toString('utf8')
}
