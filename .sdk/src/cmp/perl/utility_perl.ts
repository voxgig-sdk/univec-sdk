
import * as Path from 'node:path'

import {
  clone,
  walk,
} from '@voxgig/struct'

import { targetFeatures, canonScalarKey, requiredItems } from '@voxgig/sdkgen'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


const MODEL_META = ['index$', 'key$', 'val$']

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


// A Perl SINGLE-quoted string literal. Single quotes do not interpolate, so a
// spec-derived value containing $foo or @foo survives verbatim; only the
// backslash and the quote itself need escaping. A double-quoted literal (what
// JSON.stringify emits) would interpolate them.
function perlStringLiteral(val: string): string {
  return "'" + String(val).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'"
}


// The secrets plugin needs builtin::is_bool, from perl 5.36.
function minPerl(model: any, target: any): string {
  return null != (targetFeatures(model, target) as any).secrets ? '5.036' : '5.018'
}


function perlVersionLabel(version: string): string {
  const [major, minor] = version.split('.')
  return major + '.' + Number(minor.slice(0, 3))
}

function perlListArgs(entity: any): string {
  const lit = (type: any): string =>
    (({ NULL: 'undef', INTEGER: '1', NUMBER: '1', BOOLEAN: '1', ARRAY: '[]', OBJECT: '{}' }) as any)[canonScalarKey(type)] ?? "'example'"
  const items = requiredItems(entity, 'list')
  return 0 < items.length
    ? `({ ${items.map((it: any) => `${perlStringLiteral(it.name)} => ${lit(it.type)}`).join(', ')} })`
    : ''
}


export {
  perlListArgs,
  perlStringLiteral,
  clean,
  projectPath,
  minPerl,
  perlVersionLabel,
}
