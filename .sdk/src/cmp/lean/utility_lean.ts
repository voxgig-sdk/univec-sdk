import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'

import {
  each,
  targetFeatures,
} from '@voxgig/sdkgen'


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



function leanSecrets(model: any, target: any): {
  active: boolean, imports: string[], defs: string[], ffi: boolean,
} {
  const feature = targetFeatures(model, target)
  const secrets = feature.secrets

  if (null == secrets) {
    return { active: false, imports: [], defs: [], ffi: false }
  }

  const imports = new Set<string>()
  const defs: string[] = []

  each(secrets.plugin, (plugin: any) => {
    // Filter on `active` HERE rather than trusting the feature object to
    // arrive filtered (see Config_ts.pluginImports): the wrong reading
    // emits an import for a module the plugin trim just deleted.
    if (false === plugin.active || null == plugin.active) return

    for (const [sym, one] of Object.entries(plugin.def?.lean || {})) {
      const mod = String(one)
        .replace(/^src\/feature\/secrets\/sekreto\/plugins\//, '')
        .replace(/\.lean$/, '')
        .replace(/\//g, '.')
      imports.add(mod)
      defs.push(sym)
    }
  })

  return {
    active: true,
    imports: Array.from(imports).sort(),
    defs: defs.sort(),
    ffi: 0 < defs.length,
  }
}


export {
  clean,
  leanSecrets,
  leanString,
  leanVarName,
  pkgName,
  projectPath,
}
