// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/config.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The declarative document (§9): normalization, and the ten-level
 * precedence ladder.
 *
 * TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
 *
 * `normalizeconfig` normalizes STRUCTURE and ENTRY KEYS. It does not
 * merge options, and cannot: §9.4 makes merge behaviour a property of
 * the definition's option SHAPE, which normalization has never seen. A
 * normalizer that flattened the option layers would make
 * `$MERGE: append` unimplementable at load time, because the layers it
 * must concatenate would already be collapsed.
 *
 * `resolveoptions` applies the ladder, and it is the only place that
 * knows the shape. */

'use strict'

const { fail } = require('./types')
const { canonref, parseref } = require('./ref')

// ---------------------------------------------------------------------
// normalizeconfig
// ---------------------------------------------------------------------

function normalizeconfig(input) {
  const doc = (input && input.doc) || {}
  const keys = (input && input.keys) || {}
  const ikey = keys.instance || 'instance'
  const dkey = keys.default || 'default'
  const reserved = (input && input.reserved) || []
  const profile = input && input.profile

  // The rename is applied at TWO PLACES AND NO OTHERS: the document
  // root, and every profile.<name> overlay root (§9.1). A rename applied
  // only at the root would leave `profile.prod.sdk` untranslated and
  // silently drop every environment override the host depends on.
  // Recursing further would be worse: option data is the definition's.
  const baseinst = doc[ikey]
  const basedef = doc[dkey] || {}

  const overlay = profile && doc.profile && doc.profile[profile]
  const overinst = overlay ? overlay[ikey] : undefined
  const overdef = (overlay && overlay[dkey]) || {}

  // Entry layers, base then overlay, each as {ref -> entry} plus the
  // order the form implies.
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
  const order = []
  for (const r of over.order) if (-1 === order.indexOf(r)) order.push(r)
  // The remainder keeps the BASE's own order — array position for the
  // array form, sorted refs for the map form. Re-sorting here would
  // discard an array document's positional order entirely, which is the
  // one thing the array form exists to express.
  for (const r of base.order) if (-1 === order.indexOf(r)) order.push(r)

  const instance = {}
  for (let i = 0; i < order.length; i++) {
    const ref = order[i]
    const b = base.map[ref]
    const o = over.map[ref]

    // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
    // (§9.3). A safety rule, not a tidiness one: if the overlay had its
    // defaults filled in before merging it would carry a synthesized
    // active:true and overwrite a base's false — silently re-enabling a
    // deliberately disabled integration in production.
    const active = pick(o, 'active', pick(b, 'active', true))
    const start = pick(o, 'start', pick(b, 'start', 'eager'))
    const ord = pick(o, 'order', pick(b, 'order', undefined))

    // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
    const layers = []
    const nm = parseref(ref).name
    if (basedef[nm] && undefined !== basedef[nm].options) layers.push(basedef[nm].options)
    if (b && undefined !== b.options) layers.push(b.options)
    if (overdef[nm] && undefined !== overdef[nm].options) layers.push(overdef[nm].options)
    if (o && undefined !== o.options) layers.push(o.options)

    const ent = { pos: i, active, start, optionlayers: layers }
    if (undefined !== ord) ent.order = ord
    instance[ref] = ent
  }

  // `default` DECLARES NOTHING (§9.3). It is a base for every instance
  // of that definition; it does not create one, and an entry for a name
  // with no instances is inert rather than an error — which is what
  // makes a shared library of defaults shippable.
  const defout = {}
  for (const n of Object.keys(basedef)) defout[n] = basedef[n]
  for (const n of Object.keys(overdef)) defout[n] = overdef[n]

  return { instance, order, default: defout }
}

/** Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
 * sort identically under all three, so only mixed input discriminates:
 * '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. */
function bytewise(a, b) {
  return a < b ? -1 : a > b ? 1 : 0
}

function pick(src, key, dflt) {
  return src && undefined !== src[key] ? src[key] : dflt
}

/** Both document forms reduce to {ref -> entry} plus the order the form
 * implies: array POSITION for the array form, sorted refs for the map
 * form. */
function entries(src) {
  const map = {}
  const order = []
  if (null == src) return { map, order }

  if (Array.isArray(src)) {
    for (const item of src) {
      const ref = canonref(item.ref)
      map[ref] = item
      order.push(ref)
    }
  }
  else {
    // Map-form refs arrive as KEYS, through a different path than an
    // array element's `ref` field — and must canonicalize the same way.
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
function checkreserved(ref, reserved) {
  if (0 === reserved.length) return
  const name = parseref(ref).name
  if (-1 !== reserved.indexOf(name)) {
    fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
  }
}

// ---------------------------------------------------------------------
// resolveoptions — §9.3's ten levels, and §9.4's merge directives
// ---------------------------------------------------------------------

function resolveoptions(input) {
  const shape = input.shape || {}
  checkshape(shape)

  const ref = canonref(input.ref)
  const name = parseref(ref).name
  const doc = input.doc || {}
  const overlay = input.profile && doc.profile && doc.profile[input.profile]

  // ONE ordered merge, lowest to highest. Levels 3-6 are not two
  // namespaces collapsed separately and composed afterwards: that
  // inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
  // SPECIFICITY, so a prod per-definition default would lose to a base
  // instance value.
  const layers = [
    defaultsof(shape),                          // 1
    input.hostdefaults,                         // 2
    optsof(doc.default, name),                  // 3
    optsof(doc.instance, ref),                  // 4
    optsof(overlay && overlay.default, name),   // 5
    optsof(overlay && overlay.instance, ref),   // 6
    input.env,                                  // 7
    input.hostoptions,                          // 8
    input.loadoptions,                          // 9
    input.patch,                                // 10
  ]

  let out = {}
  for (const layer of layers) {
    if (null == layer) continue
    out = mergeone(out, layer, shape)
  }
  return out
}

/** The shape's non-directive values are the level-1 defaults. */
function defaultsof(shape) {
  const out = {}
  for (const k of Object.keys(shape)) {
    const v = shape[k]
    if (v && 'object' === typeof v && !Array.isArray(v) && undefined !== v.$MERGE) continue
    out[k] = v
  }
  return out
}

function optsof(src, key) {
  if (null == src) return undefined
  // The array form is equivalent to the map form (§9.1).
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

/** Merge ONE layer onto the accumulator, honouring the shape's
 * directives. The directive holds at EVERY precedence level, not only
 * between document levels — §9.4 makes it a property of the shape, which
 * does not know which layer a value arrived from. */
function mergeone(base, over, shape) {
  if (null == over) return base
  if (!isMap(base) || !isMap(over)) return clone(over)

  const out = {}
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

/** Merge N levels below this key, replace below that. */
function deepto(base, over, n) {
  if (n <= 0) return clone(over)
  if (!isMap(base) || !isMap(over)) return clone(over)
  const out = {}
  for (const k of Object.keys(base)) out[k] = base[k]
  for (const k of Object.keys(over)) {
    out[k] = deepto(out[k], over[k], n - 1)
  }
  return out
}

/** §9.4: N is an integer of at least 1, and everything else is an error.
 *
 * `{"deep": 0}` is rejected DESPITE having an obvious reading, because
 * "replace at this key" already has a spelling and two spellings for one
 * behaviour is the defect class this repo exists to avoid. */
const MERGE_WORDS = ['replace', 'append']

function checkshape(shape) {
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
          'invalid $MERGE deep at ' + k + ': ' + JSON.stringify(n),
          { key: k, directive: d })
      }
      continue
    }
    fail('plugin_shape_invalid',
      'invalid $MERGE directive at ' + k + ': ' + JSON.stringify(d),
      { key: k, directive: d })
  }
}

function isMap(v) {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}

function clone(v) {
  if (Array.isArray(v)) return v.map(clone)
  if (isMap(v)) {
    const out = {}
    for (const k of Object.keys(v)) out[k] = clone(v[k])
    return out
  }
  return v
}

module.exports = { normalizeconfig, resolveoptions, checkshape }
