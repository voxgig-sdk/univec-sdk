
import {
  clone,
  walk,
} from '@voxgig/struct'


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


// Method names on a generated struct that must never be an entity accessor.
//
// An entity called `clone` generated `pub fn clone(&self, Value)` on the SDK
// struct, which SHADOWS Clone::clone — so every `sdk.clone()` the generated
// code makes elsewhere resolved to the entity accessor and the crate failed
// with "this method takes 1 argument but 0 arguments were supplied", 16 times
// over, pointing at the call sites and never at the entity that caused it.
// `new` would collide with the struct's own constructor the same way.
//
// These are not Rust keywords, so RUST_RESERVED does not catch them; they are
// inherent or std-trait methods the generated code actually calls.
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


// A collision-free snake_case rust identifier for a model name.
function rustVarName(name: string): string {
  let snake = name.replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase()
  // No Rust identifier may begin with a digit. A `3d_id` field became
  // `pub 3_d_id: String`, which does not compile ("expected identifier, found
  // `3_d_id`") and took the whole crate with it. Prefixed with an underscore,
  // the convention cmp/c/utility_c.ts already applies.
  if (/^[0-9]/.test(snake)) {
    snake = '_' + snake
  }
  return RUST_RESERVED.has(snake) ? snake + '_' : snake
}


// The Cargo package name, e.g. voxgig-solar-sdk (mirrors the go module
// naming: org prefix from model.origin).
function crateName(model: any): string {
  const org = (model.origin || 'voxgig-sdk').replace(/-sdk$/, '')
  return `${org}-${model.name}-sdk`.toLowerCase().replace(/[^a-z0-9-]/g, '-')
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


// Deep-remove meta keys (`foo$`) from a model subtree (twin of go's clean).
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



// The JSON as a Rust RAW string literal.
//
// A raw string processes no escapes, so the JSON's own `\n` and `\uXXXX`
// survive byte for byte and reach the JSON parser as written - which a normal
// Rust string would not, having consumed them itself. The hash level is raised
// until its terminator does not occur in the text.
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
