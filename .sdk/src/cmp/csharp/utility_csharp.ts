
import * as Path from 'node:path'


import {
  camelify,
  each,
  safeVarName,
} from '@voxgig/sdkgen'

import {
  clone,
  walk,
} from '@voxgig/struct'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


// A camelCase C# local-variable identifier for a snake_case model name
// (`status_embed_config` -> `statusEmbedConfig`). C# contextual keywords
// that are illegal as locals get the shared reserved-word guard (js set is
// the closest match for C#'s expression keywords like `new`/`this`).
function csVarName(name: string): string {
  const pascal = camelify(name)
  const lower = pascal.charAt(0).toLowerCase() + pascal.slice(1)
  return CS_RESERVED.has(lower) ? lower + '_' : lower
}


// A PascalCase C# identifier for a snake_case model name.
function csPascalName(name: string): string {
  return camelify(name)
}


// C# keywords - illegal as a plain local-variable binding.
const CS_RESERVED = new Set<string>([
  'abstract', 'as', 'base', 'bool', 'break', 'byte', 'case', 'catch',
  'char', 'checked', 'class', 'const', 'continue', 'decimal', 'default',
  'delegate', 'do', 'double', 'else', 'enum', 'event', 'explicit',
  'extern', 'false', 'finally', 'fixed', 'float', 'for', 'foreach',
  'goto', 'if', 'implicit', 'in', 'int', 'interface', 'internal', 'is',
  'lock', 'long', 'namespace', 'new', 'null', 'object', 'operator',
  'out', 'override', 'params', 'private', 'protected', 'public',
  'readonly', 'ref', 'return', 'sbyte', 'sealed', 'short', 'sizeof',
  'stackalloc', 'static', 'string', 'struct', 'switch', 'this', 'throw',
  'true', 'try', 'typeof', 'uint', 'ulong', 'unchecked', 'unsafe',
  'ushort', 'using', 'virtual', 'void', 'volatile', 'while',
])


// Render a plain JSON-like value as a C# collection-literal expression in
// the SDK's loose object model: maps -> new Dictionary<string, object?>,
// lists -> new List<object?>, scalars -> literals.
function formatCsMap(obj: any, indent: number = 0): string {
  if (obj == null) {
    return 'null'
  }

  const pad = '    '.repeat(indent)
  const padInner = '    '.repeat(indent + 1)

  if (Array.isArray(obj)) {
    if (obj.length === 0) {
      return 'new List<object?>()'
    }
    const items = obj.map(v => padInner + formatCsValue(v, indent + 1)).join(',\n')
    return `new List<object?>\n${pad}{\n${items},\n${pad}}`
  }

  if (typeof obj === 'object') {
    const entries = Object.entries(obj)
    if (entries.length === 0) {
      return 'new Dictionary<string, object?>()'
    }
    const items = entries
      .map(([k, v]) => `${padInner}[${formatCsString(k)}] = ${formatCsValue(v, indent + 1)}`)
      .join(',\n')
    return `new Dictionary<string, object?>\n${pad}{\n${items},\n${pad}}`
  }

  return formatCsValue(obj, indent)
}


// C# NEW-LINE CHARACTERS, which a regular quoted string literal may not
// contain: U+000D, U+000A, U+0085 (NEL), U+2028 (LINE SEPARATOR) and U+2029
// (PARAGRAPH SEPARATOR) - C# language spec, "Line terminators".
//
// The first two everyone escapes. The other three are the trap: they are
// ordinary characters in JSON, in every other target language, and to the eye,
// so a model string carrying one (an OpenAPI description, default or example
// pasted from a word processor) emits a C# source file that fails to compile
// with `error CS1010: Newline in constant`. Verified against .NET 8.
//
// Written as ESCAPES, not as the characters themselves: U+2028 and U+2029
// are line terminators in JavaScript too, so a regex literal containing them
// verbatim does not parse ("Invalid regular expression: missing /") and this
// module fails to load. The same trap, one language up.
const CS_NEWLINE = /[\u0085\u2028\u2029]/g

function csEscapeNewlines(s: string): string {
  return s.replace(CS_NEWLINE,
    (c) => '\\u' + (c.codePointAt(0) as number).toString(16).padStart(4, '0'))
}


function formatCsString(val: string): string {
  return '"' + csEscapeNewlines(val
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/\t/g, '\\t')) + '"'
}


// The whole config JSON as a C# string literal.
//
// JSON.stringify output is otherwise a valid C# literal - every escape it
// emits means the same thing in C#, and it never emits \/ or \0 - but it
// leaves U+0085/U+2028/U+2029 RAW, and those three end a C# string literal.
function csStringLiteral(s: string): string {
  return csEscapeNewlines(JSON.stringify(s))
}


// A number as a C# literal whose BOXED TYPE is predictable.
//
// C# gives an unsuffixed integer literal the first type of int/uint/long/ulong
// that fits it, so `3000000000` boxes as uint while `5` boxes as int and
// `5000000000` as long. Boxed numerics compare by exact type - (object)5L does
// not Equals (object)5 - so the type a config number lands with is observable
// to every consumer, and the L1 data branch has to be able to reproduce it.
// Reproducing a uint band nothing else in the SDK ever produces is not worth
// it, so the suffix is made explicit instead and the ladder is just int -> long
// -> double, which SdkConfig.ConfigValue mirrors exactly.
//
// THE RANGE TEST IS ON THE EMITTED TEXT, not on the JS number.
//
// `String(val)` is exactly what JSON.stringify puts in the data branch, and it
// prints a double as the SHORTEST decimal that round-trips - which for a value
// near the 64-bit boundary is not the value's exact decimal expansion. The
// clearest case is long.MinValue: `String(-9223372036854775808)` is
// "-9223372036854776000", which is BELOW long.MinValue, so TryGetInt64 refuses
// it and the data branch yields a double. Deciding from the JS value instead
// emitted `long.MinValue` and the two branches disagreed at exactly that
// boundary. Comparing the text as a BigInt makes both sides ask the same
// question of the same digits.
//
// int.MinValue is written by name: `-2147483648` parses as unary minus applied
// to a literal that does not itself fit in an int, and relying on the special
// case for that is needless subtlety. There is deliberately no long.MinValue
// twin - no JS number prints as that text, so it is unreachable.
//
// A non-finite value emits `null`, because that is what JSON.stringify does
// with it - so the two representations still agree.
const CS_INT_MIN = -2147483648n
const CS_INT_MAX = 2147483647n
const CS_LONG_MIN = -9223372036854775808n
const CS_LONG_MAX = 9223372036854775807n

function formatCsNumber(val: number): string {
  if (!Number.isFinite(val)) {
    return 'null'
  }
  const text = String(val)
  // An integer TOKEN, not merely an integral value: `String` switches to
  // exponential form at 1e21, which is not an integer literal on either side.
  if (Number.isInteger(val) && /^-?\d+$/.test(text)) {
    const n = BigInt(text)
    if (CS_INT_MIN <= n && n <= CS_INT_MAX) {
      return CS_INT_MIN === n ? 'int.MinValue' : text
    }
    if (CS_LONG_MIN <= n && n <= CS_LONG_MAX) {
      return text + 'L'
    }
  }
  // Fractional, or outside the long range: a double literal. The `D` suffix is
  // required for the whole-valued case, where the digits alone would be read
  // as an integer literal (and rejected as too large).
  return text + 'D'
}


function formatCsValue(val: any, indent: number = 0): string {
  if (val === null || val === undefined) {
    return 'null'
  }
  if (typeof val === 'string') {
    return formatCsString(val)
  }
  if (typeof val === 'number') {
    return formatCsNumber(val)
  }
  if (typeof val === 'boolean') {
    return val ? 'true' : 'false'
  }
  if (Array.isArray(val)) {
    return formatCsMap(val, indent)
  }
  if (typeof val === 'object') {
    return formatCsMap(val, indent)
  }
  return String(val)
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
  csPascalName,
  csStringLiteral,
  csVarName,
  formatCsMap,
  formatCsValue,
  formatCsString,
  projectPath,
}
