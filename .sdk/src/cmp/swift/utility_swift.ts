
import * as Path from 'node:path'

import {
  camelify,
  targetFeatures,
} from '@voxgig/sdkgen'

import {
  clone,
  walk,
} from '@voxgig/struct'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


function swiftVarName(name: string): string {
  const pascal = camelify(name)
  const lower = pascal.charAt(0).toLowerCase() + pascal.slice(1)
  if (SWIFT_RESERVED.has(lower)) {
    return lower + '_'
  }
  return leadingDigitSafe(lower)
}


function leadingDigitSafe(ident: string): string {
  return /^[0-9]/.test(ident) ? '_' + ident : ident
}


// A PascalCase Swift identifier for a snake_case model name.
function swiftPascalName(name: string): string {
  return leadingDigitSafe(camelify(name))
}


// Swift keywords - illegal as a plain local-variable binding.
const SWIFT_RESERVED = new Set<string>([
  'associatedtype', 'class', 'deinit', 'enum', 'extension', 'fileprivate',
  'func', 'import', 'init', 'inout', 'internal', 'let', 'open', 'operator',
  'private', 'precedencegroup', 'protocol', 'public', 'rethrows', 'static',
  'struct', 'subscript', 'typealias', 'var', 'break', 'case', 'catch',
  'continue', 'default', 'defer', 'do', 'else', 'fallthrough', 'for', 'guard',
  'if', 'in', 'repeat', 'return', 'switch', 'where', 'while', 'as', 'false',
  'is', 'nil', 'self', 'super', 'throw', 'throws', 'true', 'try', 'any',
  'some', 'await', 'actor',
])


// Escape a string for a Swift double-quoted literal.
function swiftString(val: string): string {
  return '"' + val
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/\t/g, '\\t') + '"'
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


function swiftTargetDir(model: any): string {
  return model.const.Name + 'Sdk'
}


function swiftTestDir(model: any): string {
  return swiftTargetDir(model) + 'Tests'
}


function swiftSecretsActive(model: any, target: any): boolean {
  return null != targetFeatures(model, target)['secrets']
}


export {
  clean,
  projectPath,
  swiftPascalName,
  swiftSecretsActive,
  swiftTargetDir,
  swiftTestDir,
  swiftVarName,
  swiftString,
}
