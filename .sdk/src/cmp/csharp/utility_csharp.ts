
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


function csVarName(name: string): string {
  const pascal = camelify(name)
  const lower = pascal.charAt(0).toLowerCase() + pascal.slice(1)
  return CS_RESERVED.has(lower) ? lower + '_' : lower
}


function csPascalName(name: string): string {
  return camelify(name)
}


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
