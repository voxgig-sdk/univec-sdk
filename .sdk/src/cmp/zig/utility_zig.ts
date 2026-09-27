
import {
  clone,
  walk,
} from '@voxgig/struct'


// Zig keywords that are illegal as a plain identifier.
const ZIG_RESERVED = new Set<string>([
  'addrspace', 'align', 'allowzero', 'and', 'anyframe', 'anytype', 'asm',
  'async', 'await', 'break', 'callconv', 'catch', 'comptime', 'const',
  'continue', 'defer', 'else', 'enum', 'errdefer', 'error', 'export',
  'extern', 'fn', 'for', 'if', 'inline', 'noalias', 'nosuspend', 'noinline',
  'opaque', 'or', 'orelse', 'packed', 'pub', 'resume', 'return',
  'linksection', 'struct', 'suspend', 'switch', 'test', 'threadlocal', 'try',
  'union', 'unreachable', 'usingnamespace', 'var', 'volatile', 'while',
])


// A collision-free snake_case zig identifier for a model name.
function zigVarName(name: string): string {
  const snake = name.replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase()
  return ZIG_RESERVED.has(snake) ? snake + '_' : snake
}


function zigModuleName(model: any): string {
  const name = `${model.name}_sdk`.toLowerCase().replace(/[^a-z0-9_]/g, '_')
  return /^[0-9]/.test(name) ? '_' + name : name
}


function zigPackageFingerprint(name: string): string {
  // CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) — the one zig's
  // std.hash.Crc32 and zlib both compute.
  let crc = 0xffffffff
  for (let i = 0; i < name.length; i++) {
    crc ^= name.charCodeAt(i) & 0xff
    for (let b = 0; b < 8; b++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1))
    }
  }
  const checksum = (crc ^ 0xffffffff) >>> 0

  // FNV-1a 32-bit, folded into the 1..0xfffffffe zig accepts.
  let fnv = 0x811c9dc5
  for (let i = 0; i < name.length; i++) {
    fnv ^= name.charCodeAt(i) & 0xff
    fnv = Math.imul(fnv, 0x01000193) >>> 0
  }
  const id = (fnv % 0xfffffffd) + 1

  const hex = (n: number) => n.toString(16).padStart(8, '0')
  return `0x${hex(checksum)}${hex(id)}`
}


// Render a JSON-shaped JS value as zig source constructing the equivalent
// voxgig struct Value via the `h` (helpers) namespace. Byte-stable (each()
// sorted-key iteration upstream).
function formatZigValue(val: any, indent: number = 0): string {
  const pad = '    '.repeat(indent)
  const padInner = '    '.repeat(indent + 1)

  if (val === null || val === undefined) {
    return 'h.vnull()'
  }
  if (typeof val === 'string') {
    return `h.vstr(${JSON.stringify(val)})`
  }
  if (typeof val === 'number') {
    return Number.isInteger(val) ? `h.vnum(${val})` : `h.vfloat(${val})`
  }
  if (typeof val === 'boolean') {
    return `h.vbool(${val})`
  }
  if (Array.isArray(val)) {
    if (val.length === 0) {
      return 'h.olist()'
    }
    const items = val
      .map((v) => padInner + formatZigValue(v, indent + 1))
      .join(',\n')
    return `h.ja(&.{\n${items},\n${pad}})`
  }
  if (typeof val === 'object') {
    const entries = Object.entries(val)
    if (entries.length === 0) {
      return 'h.omap()'
    }
    const items = entries
      .map(
        ([k, v]) =>
          `${padInner}.{ ${JSON.stringify(k)}, ${formatZigValue(v, indent + 1)} }`
      )
      .join(',\n')
    return `h.jo(&.{\n${items},\n${pad}})`
  }
  return `h.vstr(${JSON.stringify(String(val))})`
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
  formatZigValue,
  zigModuleName,
  zigPackageFingerprint,
  zigVarName,
}
