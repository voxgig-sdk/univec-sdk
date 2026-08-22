
import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'

import {
  canonKey,
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


// A type-correct, executable Elixir literal for a field/param of the given
// canonical type. Strings render the quoted placeholder; numeric/boolean/
// collection types render a real literal so example blocks parse and run.
function elixirLit(sentinel: unknown, placeholder: string = 'example'): string {
  switch (canonKey(sentinel)) {
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


// Render a JS value as an Elixir literal term (maps -> %{"k" => v}, lists ->
// [..], strings -> "..", booleans -> true/false, null -> nil). The result is
// fed to ProjectName.Helpers.deep/1 at runtime, which lifts native terms
// into the vendored struct's node representation.
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


// Emission-time normalisation of a model subtree (L0).
//
// Always drops jostraca's iteration metadata (`$`-suffixed keys: index$,
// key$, val$). With `dropDefaults`, also drops keys whose value IS the
// default the runtime already assumes when the key is absent, which is pure
// payload — see CONFIG_DEFAULT.
//
// Rebuilds the tree rather than mutating during a walk. The previous
// implementation walked a clone calling `delete p[k]`, but walk() assigns its
// callback's result back over the child (`setprop(out, ckey, walk(...))`), so
// the delete was undone on the way out and the helper silently did nothing.
// Returning `undefined` from the callback does not fix it either: setprop
// stores undefined rather than removing the key, which then emits as a null.
//
// `dropDefaults` is opt-in and must be passed ONLY for the entity subtree.
// `active` means something different in feature config, where absent reads as
// INACTIVE (see feature_init) — dropping `active: true` there would silently
// disable the feature.
// jostraca's iteration metadata, injected by each()/names() while it walks the
// model. Listed explicitly rather than matched by trailing-dollar suffix: a
// trailing dollar is not exclusive to jostraca -- Seneca uses entity$ as real
// data -- so a blanket suffix match can silently drop a legitimate API field.
const MODEL_META = ['index$', 'key$', 'val$']

// Keys whose value IS the default the runtime already assumes when the key is
// absent, so emitting them is pure payload.
const CONFIG_DEFAULT: Record<string, any> = {
  active: true,
  req: false,
  reqd: false,
}

// Subtrees carrying user payload rather than schema. An active:true inside an
// OpenAPI example is DATA, not a default, so default-pruning stops at these
// keys and everything below them is passed through untouched.
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
