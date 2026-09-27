
import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


function formatCljValue(val: any, indent: number = 0): string {
  if (val === null || val === undefined) {
    return 'nil'
  }
  if (typeof val === 'string') {
    return cljString(val)
  }
  if (typeof val === 'number') {
    return Number.isFinite(val) ? String(val) : '0'
  }
  if (typeof val === 'boolean') {
    return val ? 'true' : 'false'
  }
  if (Array.isArray(val)) {
    if (val.length === 0) {
      return '(vs/jt)'
    }
    const pad = '  '.repeat(indent + 1)
    const items = val.map(v => pad + formatCljValue(v, indent + 1)).join('\n')
    return `(vs/jt\n${items})`
  }
  if (typeof val === 'object') {
    const keys = Object.keys(val).sort()
    if (keys.length === 0) {
      return '(vs/jm)'
    }
    const pad = '  '.repeat(indent + 1)
    const items = keys
      .map(k => `${pad}${cljString(k)} ${formatCljValue(val[k], indent + 1)}`)
      .join('\n')
    return `(vs/jm\n${items})`
  }
  return 'nil'
}


function cljString(s: string): string {
  return '"' + String(s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t')
    .replace(/\r/g, '\\r') + '"'
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



function cljStringChunks(json: string, maxBytes: number = 20000): string[] {
  const chunks: string[] = []
  let start = 0
  let bytes = 0
  for (let i = 0; i < json.length; i++) {
    const code = json.charCodeAt(i)
    // Worst case per UTF-16 unit under modified UTF-8.
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : 3
    const high = 0xd800 <= code && code <= 0xdbff
    if (maxBytes <= bytes && !high) {
      chunks.push(json.slice(start, i + 1))
      start = i + 1
      bytes = 0
    }
  }
  if (start < json.length) {
    chunks.push(json.slice(start))
  }
  return 0 === chunks.length ? [''] : chunks
}

export {
  cljStringChunks,
  clean,
  formatCljValue,
  cljString,
  projectPath,
}
