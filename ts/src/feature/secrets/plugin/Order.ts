// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Order.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { OrderBlock, OrderRef, OrderSpec, fail } from './Types'
import { parseref } from './Ref'

export type Binding = {
  ref: string
  pos: number
  order?: OrderBlock
}

export type Pin = { [name: string]: 'outermost' | 'innermost' | 'first' | 'last' }

export function resolveorder(bindings: Binding[], pin?: Pin): string[] {
  const nodes = bindings.slice()
  const byref: { [ref: string]: Binding } = {}
  for (const b of nodes) byref[b.ref] = b

  // Constraints are edges. A constraint naming an ABSENT binding is
  // satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
  // load in a host with no test plugin. That is sdkgen's __after__
  // behaviour, kept.
  const edges: { [from: string]: string[] } = {}
  for (const b of nodes) edges[b.ref] = []

  for (const b of nodes) {
    const o = b.order || {}
    // An empty list declares no constraint, so it must not be treated as one.
    if (declared(o.after)) for (const t of targets(o.after!, nodes)) edges[t].push(b.ref)
    if (declared(o.before)) for (const t of targets(o.before!, nodes)) edges[b.ref].push(t)
  }

  const indeg: { [ref: string]: number } = {}
  for (const b of nodes) indeg[b.ref] = 0
  for (const from of Object.keys(edges)) {
    for (const to of edges[from]) indeg[to] = (indeg[to] || 0) + 1
  }

  const out: string[] = []
  const ready = nodes.filter((b) => 0 === indeg[b.ref])

  while (0 < ready.length) {
    ready.sort(rank)
    const next = ready.shift() as Binding
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

function rank(a: Binding, b: Binding): number {
  const ab = band(a), bb = band(b)
  if (ab !== bb) return ab - bb
  return a.pos - b.pos
}

function band(b: Binding): number {
  const o = b.order || {}
  return 'number' === typeof o.band ? o.band : 0
}

function declared(spec?: OrderSpec): spec is OrderRef {
  return Array.isArray(spec) ? 0 < spec.length : null != spec && '' !== spec
}

function targets(spec: OrderRef, nodes: Binding[]): string[] {
  const hit: string[] = []
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

function applypin(order: string[], edges: { [from: string]: string[] }, pin?: Pin): string[] {
  if (null == pin) return order
  let out = order.slice()

  for (const name of Object.keys(pin).sort()) {
    const want = pin[name]
    const idx = out.findIndex((r) => parseref(r).name === name)
    if (-1 === idx) continue

    const wantfirst = 'first' === want || 'outermost' === want
    const ref = out[idx]
    out.splice(idx, 1)
    if (wantfirst) out.unshift(ref)
    else out.push(ref)
  }

  // Now check that the placement did not break a constraint. This is
  // the half that makes a pin a rejection rather than an override: the
  // host wins on position, but it does not get to silently discard a
  // relationship a plugin declared.
  const at: { [ref: string]: number } = {}
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
