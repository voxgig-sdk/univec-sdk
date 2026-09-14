// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/order.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Ordering (§7) — one rule, one place.
 *
 * sdkgen grew two special cases in `makeOptions` (`test`, then
 * `station`) and the third was not far off. This sort is the whole
 * replacement, and the tiers are in this order for a reason:
 *
 *   1 constraints   before/after edges, by ref or by name
 *   2 bands         integer, lower first, default 0
 *   3 declaration   ties break by `pos`
 *
 * CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both
 * are present. A band expresses a genuine cross-cutting layer; a
 * constraint expresses a relationship between two specific things; and a
 * band chosen by trial and error to fix an ordering bug is a bug wearing
 * a number. */

'use strict'

const { fail } = require('./types')
const { parseref } = require('./ref')

function resolveorder(bindings, pin) {
  const nodes = bindings.slice()
  const byref = {}
  for (const b of nodes) byref[b.ref] = b

  // Constraints are edges. A constraint naming an ABSENT binding is
  // satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
  // load in a host with no test plugin. That is sdkgen's __after__
  // behaviour, kept.
  const edges = {}
  for (const b of nodes) edges[b.ref] = []

  for (const b of nodes) {
    const o = b.order || {}
    if (declared(o.after)) for (const t of targets(o.after, nodes)) edges[t].push(b.ref)
    if (declared(o.before)) for (const t of targets(o.before, nodes)) edges[b.ref].push(t)
  }

  // Stable topological sort. Among ready nodes, band first (lower runs
  // first), then `pos` — the position the DOCUMENT visibly states, not
  // the order instances happened to load and not the incarnation `seq`.
  const indeg = {}
  for (const b of nodes) indeg[b.ref] = 0
  for (const from of Object.keys(edges)) {
    for (const to of edges[from]) indeg[to] = (indeg[to] || 0) + 1
  }

  const out = []
  const ready = nodes.filter((b) => 0 === indeg[b.ref])

  while (0 < ready.length) {
    ready.sort(rank)
    const next = ready.shift()
    out.push(next.ref)
    for (const to of edges[next.ref]) {
      indeg[to] -= 1
      if (0 === indeg[to]) ready.push(byref[to])
    }
  }

  if (out.length !== nodes.length) {
    const stuck = nodes.filter((b) => -1 === out.indexOf(b.ref)).map((b) => b.ref)
    fail('plugin_order_cycle',
      'before/after constraints cycle: ' + stuck.join(' -> '), { cycle: stuck })
  }

  return applypin(out, edges, pin)
}

function rank(a, b) {
  const ab = band(a), bb = band(b)
  if (ab !== bb) return ab - bb
  return a.pos - b.pos
}

function band(b) {
  const o = b.order || {}
  return 'number' === typeof o.band ? o.band : 0
}

/** Matching is by REF, or by NAME across all of that definition's
 * instances (§7) — which is the whole reason the two spellings exist. */
/** Was a constraint stated? An absent value and an EMPTY LIST are both
 * no-constraint - and [] is truthy, which is how this bug survives. */
function declared(spec) {
  return Array.isArray(spec) ? spec.some(one => '' !== one) : null != spec && '' !== spec
}

function targets(spec, nodes) {
  const hit = []
  // One spelling or a LIST of them; a list fans out to the UNION of what
  // each names, so after: ['a','b'] means after BOTH.
  const specs = Array.isArray(spec) ? spec : [spec]
  for (const one of specs) {
    for (const b of nodes) {
      if (hit.includes(b.ref)) continue
      if (b.ref === one) { hit.push(b.ref); continue }
      if (parseref(b.ref).name === one) hit.push(b.ref)
    }
  }
  return hit
}

/** A PIN IS NOT A CONSTRAINT (§7).
 *
 * Constraints and bands are negotiable by definition — they are what
 * plugins and documents say they want, and the sort's job is to satisfy
 * them all. A pin is the host stating a structural invariant of its own
 * architecture, which is a different kind of claim and must not lose a
 * tie to a document.
 *
 * So a pin PLACES the binding at the named end, and an ordering that
 * would move it away is `plugin_order_pinned` — rejected, not honoured
 * into a broken wrap. */
function applypin(order, edges, pin) {
  if (null == pin) return order
  let out = order.slice()

  // SORTED, not insertion order. A pin map is data — it can arrive from
  // a host's own construction options in any order, and two names pinned
  // to the same end are order-sensitive (`{b:'first', a:'first'}` and
  // `{a:'first', b:'first'}` give different results). JavaScript's
  // `Object.keys` is insertion order and a Go map has none at all, so
  // leaving it unstated made the same declaration mean different things
  // in different ports.
  for (const name of Object.keys(pin).sort()) {
    const want = pin[name]
    const idx = out.findIndex((r) => parseref(r).name === name)
    if (-1 === idx) continue

    // `first`/`outermost` is index 0; `last`/`innermost` is the end.
    // §6.2 makes the first chain binding outermost, which is why the
    // vocabulary is positional and why the two spellings pair this way.
    const wantfirst = 'first' === want || 'outermost' === want
    const ref = out[idx]
    out.splice(idx, 1)
    if (wantfirst) out.unshift(ref)
    else out.push(ref)
  }

  // Now check that the placement did not break a constraint. This is the
  // half that makes a pin a rejection rather than an override: the host
  // wins on position, but it does not get to silently discard a
  // relationship a plugin declared.
  const at = {}
  out.forEach((r, i) => { at[r] = i })
  for (const from of Object.keys(edges)) {
    for (const to of edges[from]) {
      if (at[from] > at[to]) {
        fail('plugin_order_pinned',
          'a pin would move a binding an ordering constrains: ' +
          from + ' must precede ' + to,
          { before: from, after: to })
      }
    }
  }

  return out
}

module.exports = { resolveorder }
