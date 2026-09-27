
import {
  clone,
  walk,
} from '@voxgig/struct'

import { sdkName } from '@voxgig/sdkgen'


// Rust keywords (strict + reserved) that are illegal as an identifier.
// sdkgen's shared safeVarName has no rust entry, so the guard lives here.
const RUST_RESERVED = new Set<string>([
  'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
  'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in',
  'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return',
  'self', 'Self', 'static', 'struct', 'super', 'trait', 'true', 'type',
  'unsafe', 'use', 'where', 'while',
  'abstract', 'become', 'box', 'do', 'final', 'macro', 'override', 'priv',
  'try', 'typeof', 'unsized', 'virtual', 'yield',
])


const RUST_METHOD_RESERVED = new Set<string>([
  'clone', 'new', 'default', 'drop', 'from', 'into', 'to_string',
  'as_ref', 'as_mut', 'borrow', 'borrow_mut', 'deref', 'deref_mut',
  'eq', 'ne', 'cmp', 'partial_cmp', 'hash', 'fmt', 'next', 'iter',
])


// A snake_case rust METHOD name for a model name — rustVarName, plus a guard
// against shadowing a method the generated code calls on the same struct.
function rustMethodName(name: string): string {
  const ident = rustVarName(name)
  return RUST_METHOD_RESERVED.has(ident) ? ident + '_' : ident
}


function rustVarName(name: string): string {
  let snake = name.replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase()
  if (/^[0-9]/.test(snake)) {
    snake = '_' + snake
  }
  return RUST_RESERVED.has(snake) ? snake + '_' : snake
}


function crateName(model: any): string {
  const org = (model.origin || 'voxgig-sdk').replace(/-sdk$/, '')
  return `${org}-${sdkName(model.name)}`.toLowerCase().replace(/[^a-z0-9-]/g, '-')
}


// The rust library (crate) identifier used in `use <crate>::...` paths,
// e.g. solar_sdk. This is the RUSTCRATE placeholder value.
function crateIdent(model: any): string {
  return `${model.name}_sdk`.toLowerCase().replace(/[^a-z0-9_]/g, '_')
}


// Render a JSON-shaped JS value as rust source constructing the equivalent
// voxgig struct Value (the rust twin of go's formatGoMap).
function formatRustValue(val: any, indent: number = 0): string {
  const pad = '    '.repeat(indent)
  const padInner = '    '.repeat(indent + 1)

  if (val === null || val === undefined) {
    return 'Value::Null'
  }
  if (typeof val === 'string') {
    return `Value::str(${JSON.stringify(val)})`
  }
  if (typeof val === 'number') {
    return `Value::Num(${Number.isInteger(val) ? val + 'f64' : String(val)})`
  }
  if (typeof val === 'boolean') {
    return `Value::Bool(${val})`
  }
  if (Array.isArray(val)) {
    if (val.length === 0) {
      return 'Value::empty_list()'
    }
    const items = val
      .map((v) => padInner + formatRustValue(v, indent + 1))
      .join(',\n')
    return `Value::list(vec![\n${items},\n${pad}])`
  }
  if (typeof val === 'object') {
    const entries = Object.entries(val)
    if (entries.length === 0) {
      return 'Value::empty_map()'
    }
    const items = entries
      .map(
        ([k, v]) =>
          `${padInner}(${JSON.stringify(k)}.to_string(), ${formatRustValue(v, indent + 1)})`
      )
      .join(',\n')
    return `Value::map_of([\n${items},\n${pad}])`
  }
  return `Value::str(${JSON.stringify(String(val))})`
}


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



function rustRawString(s: string): string {
  let level = 0
  while (s.includes('"' + '#'.repeat(level))) {
    level++
  }
  const hashes = '#'.repeat(level)
  return 'r' + hashes + '"' + s + '"' + hashes
}

export {
  rustMethodName,
  rustRawString,
  clean,
  crateIdent,
  crateName,
  formatRustValue,
  rustVarName,
}
