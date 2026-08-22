
import {
  clone,
  walk,
} from '@voxgig/struct'


// C reserved keywords illegal as identifiers.
const C_RESERVED = new Set<string>([
  'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do',
  'double', 'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline',
  'int', 'long', 'register', 'restrict', 'return', 'short', 'signed', 'sizeof',
  'static', 'struct', 'switch', 'typedef', 'union', 'unsigned', 'void',
  'volatile', 'while', 'bool', 'true', 'false',
])


// A collision-free snake_case C identifier for a model name.
function cVarName(name: string): string {
  let snake = String(name).replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase()
  if (/^[0-9]/.test(snake)) snake = '_' + snake
  return C_RESERVED.has(snake) ? snake + '_' : snake
}


// The C project identifier used as a function-name prefix, e.g. solar. Must
// match the SQUASHED `projectname` token that the umbrella header/fragment use
// for the constructor (`<ident>_sdk_new`): a hyphenated slug
// (bluefin-decryptx-p2pe) squashes to `bluefindecryptxp2pe`, so drop every
// non-alphanumeric char rather than mapping them to `_` (which produced
// `bluefin_decryptx_p2pe_sdk_new` callers that never linked against the
// squashed definition). No-op for single-word names.
function cIdent(model: any): string {
  return String(model.name).toLowerCase().replace(/[^a-z0-9]/g, '')
}


// Package-ish name (used in comments only), e.g. voxgig-solar-sdk.
function cName(model: any): string {
  const org = (model.origin || 'voxgig-sdk').replace(/-sdk$/, '')
  return `${org}-${model.name}-sdk`.toLowerCase().replace(/[^a-z0-9-]/g, '-')
}


// Render a JSON-shaped JS value as C source constructing the equivalent
// voxgig struct Value (the C twin of formatRustValue / formatGoMap). Uses
// the SDK helper builders declared in sdk.h: cmap / clist / v_str / v_num /
// v_bool / v_null.
function formatCValue(val: any, indent: number = 0): string {
  const pad = '  '.repeat(indent)
  const padInner = '  '.repeat(indent + 1)

  if (val === null || val === undefined) {
    return 'v_null()'
  }
  if (typeof val === 'string') {
    return `v_str(${JSON.stringify(val)})`
  }
  if (typeof val === 'number') {
    return `v_num(${Number.isFinite(val) ? val : 0})`
  }
  if (typeof val === 'boolean') {
    return `v_bool(${val})`
  }
  if (Array.isArray(val)) {
    if (val.length === 0) {
      return 'v_list()'
    }
    const items = val
      .map((v) => padInner + formatCValue(v, indent + 1))
      .join(',\n')
    return `clist(${val.length},\n${items})`
  }
  if (typeof val === 'object') {
    const entries = Object.entries(val)
    if (entries.length === 0) {
      return 'v_map()'
    }
    const items = entries
      .map(
        ([k, v]) =>
          `${padInner}${JSON.stringify(k)}, ${formatCValue(v, indent + 1)}`
      )
      .join(',\n')
    return `cmap(${entries.length},\n${items})`
  }
  return `v_str(${JSON.stringify(String(val))})`
}


// Deep-remove meta keys (`foo$`) from a model subtree (twin of go/rust clean).
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



// The JSON as a C string literal, split into ADJACENT literals.
//
// C99 only guarantees 4095 characters in a single string literal, and a real
// model runs to hundreds of kilobytes. Adjacent literals are concatenated by
// the translation phase before that limit applies, so this stays portable
// rather than relying on gcc/clang having no practical limit.
//
// Only `\` and `"` need escaping: JSON.stringify output contains no raw
// control characters (it writes them as the six TEXT characters \u00XX), and
// C string literals take UTF-8 bytes verbatim. Escaping the backslash also
// means no `\uXXXX` ever reaches the C lexer, which matters - a universal
// character name below 0xA0 is ill-formed C, so the JSON's own escapes would
// have been rejected if they had been passed through.
//
// Chunks are cut from the RAW text and escaped afterwards, so a cut can never
// land inside an escape sequence. Surrogate pairs are kept whole, or the cut
// would emit a lone surrogate as invalid UTF-8.
function cStringLiteral(json: string, chunkSize: number = 2000): string {
  const parts: string[] = []
  let i = 0
  while (i < json.length) {
    let end = Math.min(i + chunkSize, json.length)
    const code = json.charCodeAt(end - 1)
    if (end < json.length && 0xd800 <= code && code <= 0xdbff) {
      end++
    }
    parts.push(json.slice(i, end))
    i = end
  }
  return parts
    .map((p) => '  "' + p.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"')
    .join('\n')
}

export {
  cStringLiteral,
  clean,
  cIdent,
  cName,
  cVarName,
  formatCValue,
}
