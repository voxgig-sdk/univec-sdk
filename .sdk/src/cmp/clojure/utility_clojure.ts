
import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


// Render a JSON-shaped value as Clojure source that builds the equivalent
// vendored-struct value node: maps -> (vs/jm "k" v ...), arrays -> (vs/jt v
// ...), scalars -> literals. Keys are emitted in sorted order for byte-stable
// output. Empty map/array render as (vs/jm) / (vs/jt), so the result is valid
// for 0, 1 or N entries (N-feature-safe).
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


// Remove `$`-suffixed model annotation keys (mirrors utility_rb.clean).
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



// The JSON as Clojure string literals, CHUNKED, joined at load.
//
// A Clojure string literal becomes a JVM constant-pool UTF-8 entry, and those
// are capped at 65,535 bytes. One constant therefore cannot hold a config
// large enough to select the data representation at all - the threshold is
// 256 KB, so every model that reaches this branch would exceed the limit.
//
// The failure is AOT-only and so is easy to miss: loading from source is fine,
// and `clojure -M:test-compile` only `require`s. It appears the moment anyone
// compiles the SDK, which is the normal path for distribution:
//
//   Execution error (IllegalArgumentException)
//     at clojure.asm.ByteVector/putUTF8 (ByteVector.java:245)
//
// java/kotlin/scala already chunk for exactly this reason (see Config_java's
// jsonAppendLines). Chunks are measured in UTF-8 BYTES, not characters, with
// a wide margin: modified UTF-8 encodes a supplementary character as six
// bytes, so a character count is not a byte count. Surrogate pairs are kept
// whole, or a cut would emit a lone surrogate.
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
