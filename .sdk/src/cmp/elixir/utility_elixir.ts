
import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'

import {
  canonKey,
  canonScalarKey,
  canonToType,
} from '@voxgig/sdkgen'


// Map a canonical type sentinel ($STRING, $INTEGER, ...) to an idiomatic
// Elixir typespec. Unknown/missing sentinels fall back to `any()` (never
// throws). Thin delegate to the SHARED canonToType 'elixir' column (the
// single source of truth per language — do not keep a local table here);
// kept as an exported function so existing importers keep working.
function elixirType(sentinel: unknown): string {
  return canonToType(sentinel, 'elixir')
}


function elixirLit(sentinel: unknown, placeholder: string = 'example'): string {
  switch (canonScalarKey(sentinel)) {
    case 'INTEGER':
    case 'NUMBER': return '1'
    case 'BOOLEAN': return 'true'
    case 'ARRAY': return '[]'
    case 'OBJECT': return '%{}'
    default: return `"${placeholder}"`
  }
}


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


function formatElixir(obj: any, indent: number = 0): string {
  const pad = '  '.repeat(indent)
  const padInner = '  '.repeat(indent + 1)

  if (obj === null || obj === undefined) {
    return 'nil'
  }

  if (Array.isArray(obj)) {
    if (obj.length === 0) {
      return '[]'
    }
    const items = obj.map(v => padInner + formatElixir(v, indent + 1)).join(',\n')
    return `[\n${items}\n${pad}]`
  }

  if (typeof obj === 'object') {
    const entries = Object.entries(obj)
    if (entries.length === 0) {
      return '%{}'
    }
    const items = entries
      .map(([k, v]) => `${padInner}${elixirString(k)} => ${formatElixir(v, indent + 1)}`)
      .join(',\n')
    return `%{\n${items}\n${pad}}`
  }

  if (typeof obj === 'string') {
    return elixirString(obj)
  }
  if (typeof obj === 'number') {
    return String(obj)
  }
  if (typeof obj === 'boolean') {
    return obj ? 'true' : 'false'
  }

  return elixirString(String(obj))
}


function elixirString(s: string): string {
  return '"' + String(s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    // `#` escaped because Elixir INTERPOLATES `\#{...}` inside a double-quoted
    // string. Without this a model value containing `#{` is evaluated as code
    // at compile time rather than emitted as text - which is both a wrong
    // value and an arbitrary-expression hole. Escaping every `#` is simpler to
    // reason about than escaping only `#{`, and `\#` is just `#` in Elixir.
    .replace(/#/g, '\\#')
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t')
    + '"'
}


const MODEL_META = ['index$', 'key$', 'val$']

const CONFIG_DEFAULT: Record<string, any> = {
  active: true,
  req: false,
  reqd: false,
}

const PAYLOAD_KEYS = ['default', 'example', 'examples']

function clean(o: any, dropDefaults?: boolean): any {
  const prune = (node: any, defaults: boolean): any => {
    if (Array.isArray(node)) {
      return node.map((n: any) => prune(n, defaults))
    }
    if (null != node && 'object' === typeof node) {
      const out: any = {}
      for (const k of Object.keys(node)) {
        if (MODEL_META.includes(k)) {
          continue
        }
        if (defaults && k in CONFIG_DEFAULT && CONFIG_DEFAULT[k] === node[k]) {
          continue
        }
        out[k] = prune(node[k], defaults && !PAYLOAD_KEYS.includes(k))
      }
      return out
    }
    return node
  }
  return prune(o, true === dropDefaults)
}


export {
  clean,
  formatElixir,
  elixirString,
  elixirType,
  elixirLit,
  projectPath,
}
