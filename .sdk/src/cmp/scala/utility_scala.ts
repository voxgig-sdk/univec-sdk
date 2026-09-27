
import * as Path from 'node:path'


import {
  camelify,
} from '@voxgig/sdkgen'

import {
  clone,
  walk,
} from '@voxgig/struct'


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


function scalaPackage(model: any): string {
  const org = String(model.origin || 'voxgig-sdk')
    .replace(/-sdk$/, '')
    .replace(/[^a-zA-Z0-9]/g, '')
    .toLowerCase()
  const name = String(model.name)
    .replace(/[^a-zA-Z0-9]/g, '')
    .toLowerCase()
  return org + '.' + name + 'sdk'
}


// Maven-style coordinates (used by Package_scala for the publish metadata).
function mavenGroupId(model: any): string {
  const org = String(model.origin || 'voxgig-sdk')
    .replace(/-sdk$/, '')
    .replace(/[^a-zA-Z0-9]/g, '')
    .toLowerCase()
  return 'com.' + org
}


const SCALA_KEYWORDS = new Set([
  'abstract', 'case', 'catch', 'class', 'def', 'do', 'else', 'enum', 'export',
  'extends', 'false', 'final', 'finally', 'for', 'forSome', 'given', 'if',
  'implicit', 'import', 'lazy', 'match', 'new', 'null', 'object', 'override',
  'package', 'private', 'protected', 'return', 'sealed', 'super', 'then',
  'this', 'throw', 'trait', 'true', 'try', 'type', 'val', 'var', 'while',
  'with', 'yield',
])


function scalaVarName(name: string): string {
  const pascal = camelify(name)
  const out = pascal.charAt(0).toLowerCase() + pascal.slice(1)
  return SCALA_KEYWORDS.has(out) ? out + '_' : out
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

function cleanModel(o: any, dropDefaults?: boolean): any {
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


// Render a JSON-able value as Scala source that rebuilds it via a
// StringBuilder of JSON chunks (parsed at runtime by utility/Json.java).
// Each line becomes its own append so no single string constant can approach
// the JVM 64KB class-file limit however large the API model gets.
function jsonAppendLines(value: any, bufname: string): string {
  const json = JSON.stringify(value, null, 1)
  return json
    .split('\n')
    .map((line) =>
      `    ${bufname}.append(${JSON.stringify(line)})\n`)
    .join('')
}


export {
  cleanModel,
  mavenGroupId,
  jsonAppendLines,
  projectPath,
  scalaPackage,
  scalaVarName,
}
