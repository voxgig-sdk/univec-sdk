// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/Sekreto.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { checktag, formatref, makecatalog, makehost } from '../plugin'
import type { Catalog, Definition, Host } from '../plugin'

import { ERROR_CODE, PROVIDER_EXPORT, Provider, ProviderSpec } from './provider/support'
import { BUILTINS, KINDS } from './provider/builtin'

export type Name = string

export type SekretoOptions = {
  providers?: (Provider | ProviderSpec)[]
  /** The provider kinds beyond the built-ins that `providers` may name,
   * as voxgig/plugin definitions. Static and explicit: the calling
   * project imports the plugins it needs and passes them here, and a
   * kind it did not pass is unknown to this Sekreto. */
  plugins?: Definition[]
  cache?: boolean
}

export class SekretoError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SekretoError'
  }
}

const NAMEPART = /^[a-z0-9_]+$/

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

export function redact(text: string, values: string[]): string {
  let out = 'string' === typeof text ? text : ''

  const usable = (values || []).filter(
    (value) => 'string' === typeof value && 4 <= value.length,
  )

  for (const value of [...usable].sort((left, right) => right.length - left.length)) {
    out = out.split(value).join('[redacted]')
  }

  return out
}

/** One provider in the chain, under the store name it answers to, and
 * the ref of the plugin instance that built it - '' for a live provider
 * handed in directly, which no instance backs. */
type Entry = { store: string; ref: string; provider: Provider }

type Cached = { store: string; name: Name; value: string }

function storename(provider: Provider): string {
  return provider.describe().split(':')[0]
}

function unknownkind(kind: any, catalog: Catalog): string {
  const known = -1 !== KINDS.plugin.indexOf(String(kind))
  return (
    'sekreto: unknown provider kind: ' + String(kind) +
    ' (available: ' + catalog.names().join(', ') + ')' +
    (known ? ' - ' + String(kind) + ' is a sekreto plugin, not built in: pass it in the plugins option' : '')
  )
}

function unwrap(err: any): any {
  if (err && ERROR_CODE === err.code && err.details && 'string' === typeof err.details.cause) {
    return new SekretoError(err.details.cause)
  }
  return err
}

export class Sekreto {
  /** The voxgig/plugin host every spec'd provider is an instance of.
   * Read it for introspection - `host.list()` names each store's ref and
   * status - and nothing on it advances the chain. */
  readonly host: Host
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

  async get(name: Name): Promise<string> {
    const found = await this.try(name)

    if (undefined === found) {
      throw new SekretoError('sekreto: unknown secret: ' + name)
    }

    return found
  }

  async try(name: Name): Promise<string | undefined> {
    return this.resolve('', name, this.entries)
  }

  async getfrom(store: string, name: Name): Promise<string> {
    const found = await this.tryfrom(store, name)

    if (undefined === found) {
      throw new SekretoError('sekreto: unknown secret: ' + store + ':' + name)
    }

    return found
  }

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

  async has(name: Name): Promise<boolean> {
    return undefined !== (await this.try(name))
  }

  async hasin(store: string, name: Name): Promise<boolean> {
    return undefined !== (await this.tryfrom(store, name))
  }

  async all(names: Name[]): Promise<Record<string, string>> {
    const out: Record<string, string> = {}

    for (const name of names) {
      out[name] = await this.get(name)
    }

    return out
  }

  toJSON(): object {
    return { stores: this.stores() }
  }

  [Symbol.for('nodejs.util.inspect.custom')](): string {
    return 'Sekreto { stores: [ ' + this.stores().join(', ') + ' ] }'
  }

  sources(): string[] {
    return this.entries.map((entry) => entry.provider.describe())
  }

  stores(): string[] {
    const out: string[] = []

    for (const entry of this.entries) {
      if (!out.includes(entry.store)) {
        out.push(entry.store)
      }
    }

    return out
  }

  redact(text: string): string {
    return redact(text, this.seen)
  }

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

export function sekreto(options?: SekretoOptions): Sekreto {
  return new Sekreto(options)
}
