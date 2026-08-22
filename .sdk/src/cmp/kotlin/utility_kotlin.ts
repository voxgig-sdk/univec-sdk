
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


// The Kotlin package root for the generated SDK, mirroring how the go target
// derives GOMODULE: org segment from model.origin, name segment from the
// model name (e.g. origin voxgig-sdk + name solardemo -> voxgig.solardemosdk).
// Each runtime piece lives under it: <pkg>.core, <pkg>.utility,
// <pkg>.utility.struct, <pkg>.feature, <pkg>.entity, <pkg>.sdktest.
function kotlinPackage(model: any): string {
  const org = String(model.origin || 'voxgig-sdk')
    .replace(/-sdk$/, '')
    .replace(/[^a-zA-Z0-9]/g, '')
    .toLowerCase()
  const name = String(model.name)
    .replace(/[^a-zA-Z0-9]/g, '')
    .toLowerCase()
  return org + '.' + name + 'sdk'
}


// Maven/Gradle group coordinates for the generated SDK (used by Package_kotlin).
function gradleGroup(model: any): string {
  const org = String(model.origin || 'voxgig-sdk')
    .replace(/-sdk$/, '')
    .replace(/[^a-zA-Z0-9]/g, '')
    .toLowerCase()
  return 'com.' + org
}


const KOTLIN_KEYWORDS = new Set([
  // hard keywords
  'as', 'break', 'class', 'continue', 'do', 'else', 'false', 'for', 'fun',
  'if', 'in', 'interface', 'is', 'null', 'object', 'package', 'return',
  'super', 'this', 'throw', 'true', 'try', 'typealias', 'typeof', 'val',
  'var', 'when', 'while',
])


// A camelCase Kotlin identifier for a snake_case model name
// (`status_embed_config` -> `statusEmbedConfig`), with a reserved-word
// guard (a `fun`/`class` entity must not bind a Kotlin keyword).
function kotlinVarName(name: string): string {
  const pascal = camelify(name)
  const out = pascal.charAt(0).toLowerCase() + pascal.slice(1)
  return KOTLIN_KEYWORDS.has(out) ? out + '_' : out
}


// Strip model bookkeeping keys (ending in $) from a config subtree.
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


// Render a JSON-able value as Kotlin source that rebuilds it via a
// StringBuilder of JSON chunks (parsed at runtime by utility/Json.kt). Each
// line becomes its own append so no single string constant can approach the
// 64KB class-file limit. `$` is escaped as `\$` because Kotlin string
// literals treat `$` as a template-expression introducer.
function jsonAppendLines(value: any, bufname: string): string {
  const json = JSON.stringify(value, null, 1)
  return json
    .split('\n')
    .map((line) => {
      const lit = JSON.stringify(line).replace(/\$/g, '\\$')
      return `    ${bufname}.append(${lit})\n`
    })
    .join('')
}


export {
  cleanModel,
  gradleGroup,
  kotlinPackage,
  kotlinVarName,
  jsonAppendLines,
  projectPath,
}
