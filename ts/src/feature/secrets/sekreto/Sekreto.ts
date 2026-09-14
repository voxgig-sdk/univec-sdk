// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/Sekreto.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// sekreto: one interface for secrets, wherever they live.
//
// A Sekreto is an ordered chain of providers. `get` asks each in turn and
// returns the first hit, so an app can be configured from environment
// variables in development and a vault in production without changing a
// line of its own code.
//
// This file is CANONICAL. Every other port is a translation of it, and
// spec/sekreto.json is the behavioural contract they all run.

// THE CORE IMPORTS NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
// SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
// read at most a local file; every other kind is a voxgig/plugin
// definition under plugins/, and a chain may name one only if the
// calling project handed it in through `plugins`. That is what keeps an
// SDK whose chain is `[dotenv, env]` from carrying AWS request signing
// and seven HTTP vault clients. See docs/design/plugin-providers.md.
import { checktag, formatref, makecatalog, makehost } from '../plugin'
import type { Catalog, Definition, Host } from '../plugin'

import { ERROR_CODE, PROVIDER_EXPORT, Provider, ProviderSpec } from './provider/support'
import { BUILTINS, KINDS } from './provider/builtin'

/** A secret name: dot-separated lowercase segments, e.g. `api.token`. */
export type Name = string

export type SekretoOptions = {
  /** The provider chain, in resolution order. An entry is a live
   * provider, or the declarative spec of one - `{ kind, ...config }`. */
  providers?: (Provider | ProviderSpec)[]
  /** The provider kinds beyond the built-ins that `providers` may name,
   * as voxgig/plugin definitions. Static and explicit: the calling
   * project imports the plugins it needs and passes them here, and a
   * kind it did not pass is unknown to this Sekreto. */
  plugins?: Definition[]
  /** Cache resolved values (default: true). */
  cache?: boolean
}

/** Anything sekreto refuses to do: a bad name, a missing secret, a
 * provider that could not be reached. */
export class SekretoError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SekretoError'
  }
}

const NAMEPART = /^[a-z0-9_]+$/

/** Is this a well-formed secret name? */
export function validname(name: any): boolean {
  if ('string' !== typeof name || 0 === name.length) {
    return false
  }

  const parts = name.split('.')

  for (const part of parts) {
    if (!NAMEPART.test(part)) {
      return false
    }
  }

  return true
}

export function checkname(name: any): string {
  if (!validname(name)) {
    throw new SekretoError('sekreto: invalid name: ' + String(null == name ? '' : name))
  }
  return name
}

/** The environment-variable key for a name: `api.token` -> `API_TOKEN`. */
export function envkey(name: Name, prefix?: string): string {
  checkname(name)
  return (prefix || '') + name.split('.').join('_').toUpperCase()
}

/** Where a name lives in a KV vault: `api.token` -> `api` / `token`.
 *
 * A single-segment name has no path of its own, so it becomes a secret of
 * that name with the conventional field `value`. */
export function vaultref(name: Name): { path: string; field: string } {
  checkname(name)

  const parts = name.split('.')

  if (1 === parts.length) {
    return { path: parts[0], field: 'value' }
  }

  return { path: parts.slice(0, -1).join('/'), field: parts[parts.length - 1] }
}

/** A name flattened to one segment: `api.token` -> `api_token` (GCP
 * Secret Manager, `_`) or `api-token` (Azure Key Vault, `-`).
 *
 * Those stores have no path hierarchy and reject dots in ids, so the
 * dots become the store's conventional separator. With `-` as the
 * separator, underscores flatten too: Azure Key Vault's alphabet is
 * letters, digits and hyphens only, and a valid sekreto name like
 * `with_underscore` must still be representable there. (The resulting
 * `.`/`_` collision mirrors the documented envkey behaviour, where
 * both already map to `_`.) */
export function flatname(name: Name, sep: string): string {
  checkname(name)
  const flat = name.split('.').join(sep)
  return '-' === sep ? flat.split('_').join('-') : flat
}

/** The AWS SSM Parameter Store name for a name: dots become the path
 * hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
 * `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`. */
export function awsparam(name: Name, prefix?: string): string {
  checkname(name)

  let base = prefix || ''
  if ('' !== base && !base.startsWith('/')) {
    base = '/' + base
  }
  base = base.replace(/\/$/, '')

  return base + '/' + name.split('.').join('/')
}

/** Parse `.env` text into a map of raw keys to values.
 *
 * Deliberately small: `KEY=value`, optional `export`, `#` comments on their
 * own line, and single- or double-quoted values (double quotes also
 * unescape `\n`, `\r`, `\t` and `\\`). A line with no `=` is skipped. */
export function parsedotenv(text: string): Record<string, string> {
  const out: Record<string, string> = {}

  if ('string' !== typeof text) {
    return out
  }

  for (const rawline of text.split('\n')) {
    const line = rawline.replace(/\r$/, '').trim()

    if (0 === line.length || line.startsWith('#')) {
      continue
    }

    const body = line.startsWith('export ') ? line.slice(7).trim() : line

    const eq = body.indexOf('=')
    if (0 >= eq) {
      continue
    }

    const key = body.slice(0, eq).trim()
    let value = body.slice(eq + 1).trim()

    if (2 <= value.length && value.startsWith('"') && value.endsWith('"')) {
      value = unescape(value.slice(1, -1))
    } else if (2 <= value.length && value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1)
    }

    out[key] = value
  }

  return out
}

function unescape(text: string): string {
  let out = ''

  for (let index = 0; index < text.length; index++) {
    if ('\\' === text[index] && index + 1 < text.length) {
      const next = text[index + 1]
      index++
      if ('n' === next) {
        out += '\n'
      } else if ('r' === next) {
        out += '\r'
      } else if ('t' === next) {
        out += '\t'
      } else if ('\\' === next) {
        out += '\\'
      } else if ('"' === next) {
        out += '"'
      } else {
        out += '\\' + next
      }
    } else {
      out += text[index]
    }
  }

  return out
}

/** Replace known secret values in text with `[redacted]`.
 *
 * Only values of four characters or more are replaced: shorter ones are
 * too likely to appear in ordinary text, and redacting them would make
 * logs unreadable without making them safer.
 *
 * Longest first, which is not a detail. Replacing in the order the
 * values arrived meant a shorter secret that prefixes a longer one ate
 * the prefix and left the rest in the log: with `db.pass` = `abcd` from
 * the environment and `api.token` = `abcd1234` from the vault, and the
 * environment resolved first, `token=abcd1234` came out as
 * `token=[redacted]1234` — four characters of the vault token still
 * there. Longest first makes the longer secret match before anything can
 * eat its head. */
export function redact(text: string, values: string[]): string {
  let out = 'string' === typeof text ? text : ''

  const usable = (values || []).filter(
    (value) => 'string' === typeof value && 4 <= value.length,
  )

  // A copy: `values` belongs to the caller (it is `seen` when called
  // through Sekreto.redact), and sorting in place would reorder it.
  for (const value of [...usable].sort((left, right) => right.length - left.length)) {
    out = out.split(value).join('[redacted]')
  }

  return out
}

/** One provider in the chain, under the store name it answers to, and
 * the ref of the plugin instance that built it - '' for a live provider
 * handed in directly, which no instance backs. */
type Entry = { store: string; ref: string; provider: Provider }

/** One resolved value. Kept as a list rather than a map so that the store
 * a value came from stays attached, and so redaction order is stable. */
type Cached = { store: string; name: Name; value: string }

/** The store name a live provider answers to.
 *
 * `describe()` opens with the provider's kind - `hashicorp:...`,
 * `dotenv:...`, plain `env` - so the kind is the natural default, and a
 * custom provider gets a sensible name without having to implement
 * anything extra. A spec'd provider's store is its `name` or its `kind`,
 * decided before the provider exists. */
function storename(provider: Provider): string {
  return provider.describe().split(':')[0]
}

/** The message for a kind the catalog does not hold.
 *
 * A kind sekreto has never heard of is a typo; a kind that exists as a
 * plugin but was not passed in is the split working as designed and
 * telling you what to pass. Collapsing the two was the first thing that
 * made the split confusing to use. */
function unknownkind(kind: any, catalog: Catalog): string {
  const known = -1 !== KINDS.plugin.indexOf(String(kind))
  return (
    'sekreto: unknown provider kind: ' + String(kind) +
    ' (available: ' + catalog.names().join(', ') + ')' +
    (known ? ' - ' + String(kind) + ' is a sekreto plugin, not built in: pass it in the plugins option' : '')
  )
}

/** A SekretoError that crossed the plugin boundary comes back out as
 * itself, byte for byte. Anything else is not sekreto's to rewrite. */
function unwrap(err: any): any {
  if (err && ERROR_CODE === err.code && err.details && 'string' === typeof err.details.cause) {
    return new SekretoError(err.details.cause)
  }
  return err
}

/** The secrets facade: a chain of providers plus a cache.
 *
 * Two ways to read. `get` is transparent - it walks the chain and takes
 * the first hit, and the caller never learns which store answered. `getfrom`
 * is directed - it names the store, and only that store is asked. Use the
 * first for ordinary configuration, the second when *which* store holds a
 * secret is part of what you mean. */
export class Sekreto {
  /** The voxgig/plugin host every spec'd provider is an instance of.
   * Read it for introspection - `host.list()` names each store's ref and
   * status - and nothing on it advances the chain. */
  readonly host: Host
  /** The definitions this Sekreto can build: the built-ins plus what
   * `plugins` handed in. */
  readonly catalog: Catalog

  private entries: Entry[]
  private docache: boolean
  private cache: Cached[]
  // Every value ever resolved, for redact(). Kept independently of the
  // read cache so that redaction still works when cache is off - otherwise
  // `cache: false` would silently disable redact() and leak secrets to logs.
  private seen: string[]

  constructor(options?: SekretoOptions) {
    const opts = options || {}

    // Built-ins first, then the plugins, into one catalog: a plugin that
    // names a built-in kind replaces it, which is how a host substitutes
    // an implementation and never an accident, because the four names
    // are documented.
    this.catalog = makecatalog(BUILTINS.concat(opts.plugins || []))
    this.host = makehost({ catalog: this.catalog })

    this.entries = (opts.providers || []).map((entry) => {
      if ('function' === typeof (entry as Provider).lookup) {
        const provider = entry as Provider
        return { store: storename(provider), ref: '', provider }
      }
      return this.declare(entry as ProviderSpec)
    })

    this.docache = false === opts.cache ? false : true
    this.cache = []
    this.seen = []
  }

  /** One chain entry, as a plugin instance.
   *
   * The instance is `kind` for a store named after its kind and
   * `kind$store` otherwise - `hashicorp$prod` - so `host.list()` reads
   * like the chain. A store name that is already taken gets a numbered
   * tag from the host instead, because two providers MAY share a store
   * name (a directed read walks both) and an instance ref may not. */
  private declare(spec: ProviderSpec): Entry {
    const kind = null == spec ? undefined : spec.kind

    if (undefined === kind || !this.catalog.has(kind)) {
      throw new SekretoError(unknownkind(kind, this.catalog))
    }

    const store = spec.name || kind

    if (!checktag(store)) {
      throw new SekretoError('sekreto: invalid store name: ' + store)
    }

    let ref = store === kind ? kind : formatref(kind, store)
    if (undefined !== this.host.instance(ref)) {
      ref = this.host.autotag(kind)
    }

    try {
      // `load` runs the definition's `define`, which builds the provider
      // from the spec; `activate` takes the instance live. Nothing is
      // contacted by either: a provider opens nothing until its first
      // lookup.
      this.host.load(ref, { options: spec })
      this.host.activate(ref)
    } catch (err: any) {
      throw unwrap(err)
    }

    return { store, ref, provider: this.host.exports(ref + '/' + PROVIDER_EXPORT) as Provider }
  }

  /** The secret, or a SekretoError if no provider has it. */
  async get(name: Name): Promise<string> {
    const found = await this.try(name)

    if (undefined === found) {
      throw new SekretoError('sekreto: unknown secret: ' + name)
    }

    return found
  }

  /** The secret, or undefined if no provider has it. */
  async try(name: Name): Promise<string | undefined> {
    return this.resolve('', name, this.entries)
  }

  /** The secret from one named store, or a SekretoError if that store does
   * not have it. */
  async getfrom(store: string, name: Name): Promise<string> {
    const found = await this.tryfrom(store, name)

    if (undefined === found) {
      throw new SekretoError('sekreto: unknown secret: ' + store + ':' + name)
    }

    return found
  }

  /** The secret from one named store, or undefined if that store does not
   * have it.
   *
   * Naming a store that is not in the chain is an error, not a miss: `try`
   * already means "this store may not have it", so it cannot also mean
   * "this store may not exist" without hiding a typo. */
  async tryfrom(store: string, name: Name): Promise<string | undefined> {
    const matching = this.entries.filter((entry) => entry.store === store)

    if (0 === matching.length) {
      throw new SekretoError('sekreto: unknown store: ' + store)
    }

    return this.resolve(store, name, matching)
  }

  private async resolve(store: string, name: Name, entries: Entry[]): Promise<string | undefined> {
    checkname(name)

    if (this.docache) {
      const hit = this.cache.find((entry) => entry.store === store && entry.name === name)
      if (undefined !== hit) {
        return hit.value
      }
    }

    for (const entry of entries) {
      const found = await entry.provider.lookup(name)

      if (undefined !== found && null !== found) {
        if (this.docache) {
          this.cache.push({ store, name, value: found })
        }
        this.seen.push(found)
        return found
      }
    }

    return undefined
  }

  /** Does any provider have this secret? */
  async has(name: Name): Promise<boolean> {
    return undefined !== (await this.try(name))
  }

  /** Does this named store have this secret? */
  async hasin(store: string, name: Name): Promise<boolean> {
    return undefined !== (await this.tryfrom(store, name))
  }

  /** Every named secret at once. Missing ones are an error. */
  async all(names: Name[]): Promise<Record<string, string>> {
    const out: Record<string, string> = {}

    for (const name of names) {
      out[name] = await this.get(name)
    }

    return out
  }

  /** What a Sekreto shows of itself when something prints it.
   *
   * `console.log(sekreto)` and `JSON.stringify(sekreto)` both reach
   * `cache` and `seen`, which between them hold every value this chain
   * has ever resolved — so one ordinary logging call writes every secret
   * to the log. `private` is a compile-time fiction: at run time the
   * fields are ordinary and enumerable.
   *
   * `JSON.stringify` is the one that bites hardest, because a structured
   * logger serialises its whole context object without anyone writing a
   * line about secrets: `logger.info({ secrets: sekreto }, 'ready')`.
   *
   * Both hooks are needed. `toJSON` covers `JSON.stringify` and
   * everything built on it; the inspect symbol covers `console.log`,
   * `util.inspect` and the REPL. Neither reaches a value. */
  toJSON(): object {
    return { stores: this.stores() }
  }

  [Symbol.for('nodejs.util.inspect.custom')](): string {
    return 'Sekreto { stores: [ ' + this.stores().join(', ') + ' ] }'
  }

  /** A description of each provider, in resolution order. */
  sources(): string[] {
    return this.entries.map((entry) => entry.provider.describe())
  }

  /** The name of each store that can be named by `getfrom`, in resolution
   * order and without repeats. */
  stores(): string[] {
    const out: string[] = []

    for (const entry of this.entries) {
      if (!out.includes(entry.store)) {
        out.push(entry.store)
      }
    }

    return out
  }

  /** Replace every value this Sekreto has resolved with `[redacted]`.
   *
   * Works whether or not caching is enabled: the redaction list is kept
   * independently of the read cache. */
  redact(text: string): string {
    return redact(text, this.seen)
  }

  /** Drop cached values, so the next `get` asks the providers again. */
  refresh(): void {
    this.cache = []
  }

  /** Tear the chain down: every plugin instance is deactivated and
   * unloaded, in reverse, releasing whatever a provider acquired at
   * activation. Afterwards there is nothing to read from - `get` reports
   * every secret unknown - and the cache is dropped, though `redact`
   * still knows every value that was ever resolved. */
  close(): void {
    this.host.close()
    this.entries = []
    this.cache = []
  }
}

/** Make a Sekreto from options. */
export function sekreto(options?: SekretoOptions): Sekreto {
  return new Sekreto(options)
}
