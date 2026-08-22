import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


// A Lean 4 string literal. Lean strings are UTF-8, so non-ASCII passes through;
// only the structural characters need escaping. (Backticks are ordinary in Lean
// strings, so the config's `body`-style transform exprs embed verbatim.)
function leanString(s: string): string {
  let out = '"'
  for (const ch of String(s)) {
    if (ch === '"') out += '\\"'
    else if (ch === '\\') out += '\\\\'
    else if (ch === '\n') out += '\\n'
    else if (ch === '\t') out += '\\t'
    else if (ch === '\r') out += '\\r'
    else out += ch
  }
  return out + '"'
}


// Lean reserved words that cannot be bare identifiers.
const LEAN_RESERVED = new Set<string>([
  'do', 'let', 'fun', 'match', 'with', 'if', 'then', 'else', 'by', 'end',
  'namespace', 'section', 'open', 'import', 'def', 'partial', 'mutual',
  'structure', 'inductive', 'class', 'instance', 'where', 'deriving', 'return',
  'try', 'catch', 'for', 'in', 'while', 'have', 'show', 'from', 'set_option',
])


// A collision-free lower-camel Lean identifier for a model name.
function leanVarName(name: string): string {
  let s = String(name).replace(/[^a-zA-Z0-9_]/g, '_')
  if (s.length === 0) {
    s = 'x'
  }
  s = s.charAt(0).toLowerCase() + s.slice(1)
  if (!/^[a-z_]/.test(s)) {
    s = 'e_' + s
  }
  return LEAN_RESERVED.has(s) ? s + '_' : s
}


// The lowercase-hyphenated package name (used for the lake package + repo).
function pkgName(model: any): string {
  const org = (model.origin || 'voxgig-sdk').replace(/-sdk$/, '')
  return `${org}-${model.name}-sdk`.toLowerCase().replace(/[^a-z0-9-]/g, '-')
}


// Remove `$`-suffixed model annotation keys (so the embedded config is clean).
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
  leanString,
  leanVarName,
  pkgName,
  projectPath,
}
