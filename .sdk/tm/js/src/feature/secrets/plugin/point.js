// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/point.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Extension points (§6). Three kinds, chosen because they are what the
 * two existing systems actually needed, and no more.
 *
 * A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
 * deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
 * undoable, but "this instance holds slot 3 of the request chain" is
 * undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
 * paper called *Listeners Considered Harmful*, and for exactly this
 * reason. */

'use strict'

const { fail } = require('./types')

/** §6.1: "fan-out" is not one answer but four. In a language with
 * asynchrony, "call every binding" hides a decision — start them all and
 * wait, await each in turn, or do not wait — and a design that leaves it
 * unsaid gets four different answers from four ports, in the concurrency
 * behaviour of production code no corpus entry happens to cover. */
const MODES = ['emit', 'parallel', 'serial', 'bail']

/** Fan-out. Return values are ignored except in `bail`. */
function emit(bindings, mode, arg) {
  if ('bail' === mode) {
    // Stops at the first binding that RETURNS A VALUE — the "handled,
    // stop" case. A NULL DECLINES, and so does `undefined`.
    //
    // JavaScript can tell the two apart and almost nothing else in the
    // target set can — Go, Python, Ruby, PHP, Lua, Java and C# each have
    // exactly one way to say nothing. Making the distinction
    // load-bearing would cost every one of them a wrapper type carried
    // through the whole dispatch path, to express a difference their
    // plugin authors cannot write. §18's budget settles it (§6.1).
    for (const b of bindings) {
      const v = b.fn(arg)
      if (null != v) return v
    }
    return undefined
  }

  const errors = []
  for (const b of bindings) {
    try { b.fn(arg) }
    catch (err) {
      // `emit` raises synchronously; the collecting modes gather.
      if ('emit' === mode) throw err
      errors.push(err)
    }
  }
  return 'emit' === mode ? undefined : errors
}

/** Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
 *
 * Recomputed by the host whenever the live set changes, and cached
 * between changes. Plugins receive `next` as an argument; they never see
 * or store the previous value of anything. A plugin that stashes `next`
 * and calls it after deactivation is a bug the host cannot prevent, and
 * this says so rather than pretending otherwise. */
function compose(bindings, base) {
  let next = base
  for (let i = bindings.length - 1; 0 <= i; i--) {
    const fn = bindings[i].fn
    const inner = next
    next = (...args) => fn(inner, ...args)
  }
  return next
}

/** At most one live implementation (§6.3). The winner is the highest
 * band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
 * silently ignored. */
function provider(bindings, spec) {
  if (0 === bindings.length) return { shadowed: [] }

  if (spec.exclusive && 1 < bindings.length) {
    const refs = bindings.map((b) => b.ref).sort()
    fail('plugin_point_exclusive',
      'point is exclusive and has ' + bindings.length + ' bindings: ' + refs.join(', '),
      { refs })
  }

  const ranked = bindings.slice().sort((a, b) => {
    if (a.band !== b.band) return b.band - a.band     // HIGHEST band wins
    return a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0
  })

  return { winner: ranked[0], shadowed: ranked.slice(1).map((b) => b.ref) }
}

module.exports = { MODES, emit, compose, provider }
