// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Config.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { Normalized, Instance, fail } from './Types'
import { canonref, parseref } from './Ref'

// ---------------------------------------------------------------------
// normalizeconfig
// ---------------------------------------------------------------------

export type NormalizeInput = {
  doc: any
  profile?: string
  keys?: { instance?: string, default?: string }
  reserved?: string[]
}

export function normalizeconfig(input: NormalizeInput): Normalized {
  const doc = (input && input.doc) || {}
  const keys = (input && input.keys) || {}
  const ikey = keys.instance || 'instance'
  const dkey = keys.default || 'default'
  const reserved = (input && input.reserved) || []
  const profile = input && input.profile

  const baseinst = doc[ikey]
  const basedef = doc[dkey] || {}

  const overlay = profile && doc.profile && doc.profile[profile]
  const overinst = overlay ? overlay[ikey] : undefined
  const overdef = (overlay && overlay[dkey]) || {}

  const base = entries(baseinst)
  const over = entries(overinst)

  for (const r of Object.keys(base.map)) checkreserved(r, reserved)
  for (const r of Object.keys(over.map)) checkreserved(r, reserved)
  for (const n of Object.keys(basedef)) checkreserved(n, reserved)
  for (const n of Object.keys(overdef)) checkreserved(n, reserved)

  // A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
  // way: deriving order from a partial array silently dropped
  // config-activated features. Refs in the base but absent from the
  // overlay still load, in sorted position AFTER the listed ones. A
  // profile may also INTRODUCE a ref the base never declared.
  const order: string[] = []
  for (const r of over.order) if (-1 === order.indexOf(r)) order.push(r)
  // The remainder keeps the BASE's own order — array position for the
  // array form, sorted refs for the map form. Re-sorting here would
  // discard an array document's positional order entirely, which is the
  // one thing the array form exists to express.
  for (const r of base.order) if (-1 === order.indexOf(r)) order.push(r)

  const instance: { [ref: string]: Instance } = {}
  for (let i = 0; i < order.length; i++) {
    const ref = order[i]
    const b = base.map[ref]
    const o = over.map[ref]

    const active = pick(o, 'active', pick(b, 'active', true))
    const start = pick(o, 'start', pick(b, 'start', 'eager'))
    const ord = pick(o, 'order', pick(b, 'order', undefined))

    const layers: any[] = []
    const nm = parseref(ref).name
    if (basedef[nm] && undefined !== basedef[nm].options) layers.push(basedef[nm].options)
    if (b && undefined !== b.options) layers.push(b.options)
    if (overdef[nm] && undefined !== overdef[nm].options) layers.push(overdef[nm].options)
    if (o && undefined !== o.options) layers.push(o.options)

    const ent: Instance = { pos: i, active, start, optionlayers: layers }
    if (undefined !== ord) ent.order = ord
    instance[ref] = ent
  }

  // `default` DECLARES NOTHING (§9.3). It is a base for every instance
  // of that definition; it does not create one, and an entry for a name
  // with no instances is inert rather than an error — which is what
  // makes a shared library of defaults shippable.
  const defout: { [name: string]: any } = {}
  for (const n of Object.keys(basedef)) defout[n] = basedef[n]
  for (const n of Object.keys(overdef)) defout[n] = overdef[n]

  return { instance, order, default: defout }
}

/** Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
 * sort identically under all three, so only mixed input discriminates:
 * '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. */
function bytewise(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

function pick(src: any, key: string, dflt: any): any {
  return src && undefined !== src[key] ? src[key] : dflt
}

function entries(src: any): { map: { [ref: string]: any }, order: string[] } {
  const map: { [ref: string]: any } = {}
  const order: string[] = []
  if (null == src) return { map, order }

  if (Array.isArray(src)) {
    for (const item of src) {
      const ref = canonref(item.ref)
      map[ref] = item
      order.push(ref)
    }
  }
  else {
    for (const key of Object.keys(src)) {
      map[canonref(key)] = src[key]
    }
    order.push(...Object.keys(map).sort(bytewise))
  }
  return { map, order }
}

/** §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
 * too. A configuration surface that can disable the thing reading it is
 * not a surface, it is a trap. */
function checkreserved(ref: string, reserved: string[]): void {
  if (0 === reserved.length) return
  const name = parseref(ref).name
  if (-1 !== reserved.indexOf(name)) {
    fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
  }
}


export type ResolveInput = {
  ref: string
  shape?: any
  hostdefaults?: any
  doc?: any
  profile?: string
  env?: any
  hostoptions?: any
  loadoptions?: any
  patch?: any
}

export function resolveoptions(input: ResolveInput): any {
  const shape = input.shape || {}
  checkshape(shape)

  const ref = canonref(input.ref)
  const name = parseref(ref).name
  const doc = input.doc || {}
  const overlay = input.profile && doc.profile && doc.profile[input.profile]

  const layers = [
    defaultsof(shape),
    input.hostdefaults,
    optsof(doc.default, name),
    optsof(doc.instance, ref),
    optsof(overlay && overlay.default, name),
    optsof(overlay && overlay.instance, ref),
    input.env,
    input.hostoptions,
    input.loadoptions,
    input.patch,
  ]

  let out: any = {}
  for (const layer of layers) {
    if (null == layer) continue
    out = mergeone(out, layer, shape)
  }
  return out
}

function defaultsof(shape: any): any {
  const out: any = {}
  for (const k of Object.keys(shape)) {
    const v = shape[k]
    if (v && 'object' === typeof v && !Array.isArray(v) && undefined !== v.$MERGE) continue
    out[k] = v
  }
  return out
}

function optsof(src: any, key: string): any {
  if (null == src) return undefined
  if (Array.isArray(src)) {
    for (const item of src) {
      if (canonref(item.ref) === key) return item.options
    }
    return undefined
  }
  for (const k of Object.keys(src)) {
    if (canonref(k) === key) return src[k].options
  }
  return undefined
}

function mergeone(base: any, over: any, shape: any): any {
  if (null == over) return base
  if (!isMap(base) || !isMap(over)) return clone(over)

  const out: any = {}
  for (const k of Object.keys(base)) out[k] = base[k]

  for (const k of Object.keys(over)) {
    const directive = shape && shape[k] ? shape[k].$MERGE : undefined
    const b = out[k]
    const o = over[k]

    if ('replace' === directive) {
      out[k] = clone(o)
    }
    else if ('append' === directive) {
      const bl = Array.isArray(b) ? b : []
      const ol = Array.isArray(o) ? o : [o]
      out[k] = bl.concat(ol)
    }
    else if (directive && 'object' === typeof directive && undefined !== directive.deep) {
      out[k] = deepto(b, o, directive.deep)
    }
    else {
      // Library default: deep for maps, REPLACE for lists. struct.merge
      // is element-wise by index, which for option maps is nearly always
      // wrong — ["a"] over ["x","y","z"] yielding ["a","y","z"] is the
      // defect station hit on secrets.providers.
      out[k] = (isMap(b) && isMap(o)) ? mergeone(b, o, undefined) : clone(o)
    }
  }
  return out
}

function deepto(base: any, over: any, n: number): any {
  if (n <= 0) return clone(over)
  if (!isMap(base) || !isMap(over)) return clone(over)
  const out: any = {}
  for (const k of Object.keys(base)) out[k] = base[k]
  for (const k of Object.keys(over)) {
    out[k] = deepto(out[k], over[k], n - 1)
  }
  return out
}

const MERGE_WORDS = ['replace', 'append']

export function checkshape(shape: any): void {
  if (!isMap(shape)) return
  for (const k of Object.keys(shape)) {
    const v = shape[k]
    if (!isMap(v) || undefined === v.$MERGE) continue
    const d = v.$MERGE

    if ('string' === typeof d) {
      if (-1 === MERGE_WORDS.indexOf(d)) {
        fail('plugin_shape_invalid',
          'invalid $MERGE directive at ' + k + ': ' + d, { key: k, directive: d })
      }
      continue
    }
    if (isMap(d) && undefined !== d.deep) {
      const n = d.deep
      if ('number' !== typeof n || !Number.isInteger(n) || n < 1) {
        fail('plugin_shape_invalid',
          'invalid $MERGE deep at ' + k + ': ' + JSON.stringify(n), { key: k, directive: d })
      }
      continue
    }
    fail('plugin_shape_invalid',
      'invalid $MERGE directive at ' + k + ': ' + JSON.stringify(d), { key: k, directive: d })
  }
}

function isMap(v: any): boolean {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}

function clone(v: any): any {
  if (Array.isArray(v)) return v.map(clone)
  if (isMap(v)) {
    const out: any = {}
    for (const k of Object.keys(v)) out[k] = clone(v[k])
    return out
  }
  return v
}
