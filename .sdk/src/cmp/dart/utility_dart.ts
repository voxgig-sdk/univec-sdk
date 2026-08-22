
import * as Path from 'node:path'


import {
  clone,
  walk,
} from '@voxgig/struct'


// Escape a string for a single-quoted Dart string literal. `$` must be
// escaped or Dart interpolates it (model values like '`$COPY`' would break).
function dartString(s: string): string {
  return "'" + String(s)
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\$/g, '\\$')
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/\t/g, '\\t') + "'"
}


// Render a JSON-like value as a deep-dynamic Dart literal. Every map is
// emitted as `<String, dynamic>{...}` and every list as `<dynamic>[...]` so
// the runtime struct utilities can freely mutate/extend the structures
// (inferred literal types would be too narrow and throw at runtime).
function dartValue(obj: any, indent: number = 0): string {
  const pad = '  '.repeat(indent)
  const cpad = '  '.repeat(indent + 1)

  if (null == obj) {
    return 'null'
  }
  if ('string' === typeof obj) {
    return dartString(obj)
  }
  if ('number' === typeof obj) {
    return isFinite(obj) ? String(obj) : 'null'
  }
  if ('boolean' === typeof obj) {
    return obj ? 'true' : 'false'
  }
  if (Array.isArray(obj)) {
    if (0 === obj.length) {
      return '<dynamic>[]'
    }
    return '<dynamic>[\n' +
      obj.map(v => cpad + dartValue(v, indent + 1) + ',').join('\n') +
      '\n' + pad + ']'
  }
  if ('object' === typeof obj) {
    const keys = Object.keys(obj)
    if (0 === keys.length) {
      return '<String, dynamic>{}'
    }
    return '<String, dynamic>{\n' +
      keys.map(k => cpad + dartString(k) + ': ' + dartValue(obj[k], indent + 1) + ',')
        .join('\n') +
      '\n' + pad + '}'
  }
  return 'null'
}


function projectPath(suffix?: string): string {
  return Path.normalize(Path.join(__dirname, '../../..', suffix ?? ''))
}


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



// The JSON as a Dart string literal.
//
// Dart's ordinary string literals INTERPOLATE: `$name` and `${...}` are
// substitution, and the model is full of `$` - `$STRING`, `$NUMBER`,
// `$action`. A raw string (`r'...'`) would avoid that but cannot contain its
// own quote character and has no escape for it, and the JSON contains both
// quote characters in quantity.
//
// So: JSON.stringify's escaping, which already handles `"` and `\` and emits
// no raw control characters, plus `$` -> `\$`. That last step is unambiguous
// precisely because JSON.stringify has already escaped every backslash, so a
// `\$` here can only have come from this rule.
function dartStringLiteral(json: string): string {
  return JSON.stringify(json).replace(/\$/g, '\\$')
}

export {
  dartStringLiteral,
  clean,
  dartString,
  dartValue,
  projectPath,
}
