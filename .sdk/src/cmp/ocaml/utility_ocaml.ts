
import {
  clone,
  walk,
} from '@voxgig/struct'


// OCaml keywords that are illegal as a lowercase identifier. sdkgen's shared
// safeVarName has no ocaml entry, so the guard lives here.
const OCAML_RESERVED = new Set<string>([
  'and', 'as', 'assert', 'asr', 'begin', 'class', 'constraint', 'do', 'done',
  'downto', 'else', 'end', 'exception', 'external', 'false', 'for', 'fun',
  'function', 'functor', 'if', 'in', 'include', 'inherit', 'initializer',
  'land', 'lazy', 'let', 'lor', 'lsl', 'lsr', 'lxor', 'match', 'method', 'mod',
  'module', 'mutable', 'new', 'nonrec', 'object', 'of', 'open', 'or', 'private',
  'rec', 'sig', 'struct', 'then', 'to', 'true', 'try', 'type', 'val', 'virtual',
  'when', 'while', 'with',
])


// A collision-free snake_case OCaml (lowercase) identifier for a model name.
function ocamlVarName(name: string): string {
  let snake = String(name).replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase()
  if ('' === snake || !/^[a-z_]/.test(snake)) {
    snake = '_' + snake
  }
  return OCAML_RESERVED.has(snake) ? snake + '_' : snake
}


// The generated per-entity module basename (module Sdk_entity_<name>).
function entityModule(name: string): string {
  return 'sdk_entity_' + ocamlVarName(name)
}


// The opam / distribution package name, e.g. voxgig-solar-sdk (mirrors the go
// module naming: org prefix from model.origin).
function packageName(model: any): string {
  const org = (model.origin || 'voxgig-sdk').replace(/-sdk$/, '')
  return `${org}-${model.name}-sdk`.toLowerCase().replace(/[^a-z0-9-]/g, '-')
}


// Escape a JS string as an OCaml string literal body (byte string). OCaml
// accepts `\\`, `\"`, `\n`, `\r`, `\t` and decimal `\ddd` escapes; other bytes
// (incl. UTF-8) pass through literally.
function ocamlString(s: string): string {
  let out = ''
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    const code = s.charCodeAt(i)
    if ('\\' === c) out += '\\\\'
    else if ('"' === c) out += '\\"'
    else if ('\n' === c) out += '\\n'
    else if ('\r' === c) out += '\\r'
    else if ('\t' === c) out += '\\t'
    else if (code < 0x20) out += '\\' + String(code).padStart(3, '0')
    else out += c
  }
  return out
}


// Render a JSON-shaped JS value as OCaml source constructing the equivalent
// voxgig struct `value` (the OCaml twin of go's formatGoMap / rust's
// formatRustValue). Uses the sdk_helpers `jo`/`ja` builders.
function formatOcamlValue(val: any, indent: number = 0): string {
  const pad = '  '.repeat(indent)
  const padInner = '  '.repeat(indent + 1)

  if (null === val || undefined === val) {
    return 'Null'
  }
  if ('string' === typeof val) {
    return `(Str "${ocamlString(val)}")`
  }
  if ('number' === typeof val) {
    const n = Number.isInteger(val) ? val + '.' : String(val)
    return `(Num (${n}))`
  }
  if ('boolean' === typeof val) {
    return `(Bool ${val})`
  }
  if (Array.isArray(val)) {
    if (0 === val.length) {
      return '(empty_list ())'
    }
    const items = val
      .map((v) => padInner + formatOcamlValue(v, indent + 1))
      .join(';\n')
    return `(ja [\n${items} ])`
  }
  if ('object' === typeof val) {
    const entries = Object.entries(val)
    if (0 === entries.length) {
      return '(empty_map ())'
    }
    const items = entries
      .map(
        ([k, v]) =>
          `${padInner}("${ocamlString(k)}", ${formatOcamlValue(v, indent + 1)})`
      )
      .join(';\n')
    return `(jo [\n${items} ])`
  }
  return `(Str "${ocamlString(String(val))}")`
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


export {
  clean,
  entityModule,
  formatOcamlValue,
  ocamlString,
  ocamlVarName,
  packageName,
}
