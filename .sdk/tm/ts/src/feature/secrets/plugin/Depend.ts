// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Depend.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { Required } from './Capability'
import { tryref } from './Ref'
import { fail } from './Types'

/** A bare string is shorthand for `{name}`. */
export function normrequire(r: any): Required {
  return ('string' === typeof r ? { name: r } : (r || {})) as Required
}

export function requirements(options: any): Required[] {
  const raw: any[] = (options && options.requires) || []
  const marked: string[] = (options && options.optional) || []
  const fallback = options && options.policy
  return raw.map(normrequire).map((r) => {
    const out: Required = { ...r }
    if (r.optional || -1 !== marked.indexOf(r.name)) { out.optional = true }
    if (undefined === out.policy && undefined !== fallback) {
      out.policy = fallback
    }
    return out
  })
}

export function restartsonloss(r: Required): boolean {
  return 'dynamic' !== (r.policy || 'static')
}

export function gatesactivation(r: Required): boolean {
  return true !== r.optional
}

export function restartcausing(r: Required): boolean {
  return gatesactivation(r) || restartsonloss(r)
}

export type Node = {
  ref: string
  provides: string[]
  requires: Required[]
}

export function dependencycycle(nodes: Node[]): string[] | null {
  const bycap: { [cap: string]: string[] } = {}
  const isref: { [ref: string]: boolean } = {}
  for (const n of nodes) {
    isref[n.ref] = true
    for (const cap of n.provides) {
      (bycap[cap] = bycap[cap] || []).push(n.ref)
    }
  }

  const edges: { [ref: string]: string[] } = {}
  for (const n of nodes) {
    const out: string[] = []
    for (const r of n.requires) {
      if (!restartcausing(r)) continue
      const from: string[] = (bycap[r.name] || []).slice()
      // A node satisfies its own name AS A REF (§11.1), canonically —
      // exactly what `providersof` does at runtime, so the load-time
      // graph and the running one agree about what an edge is.
      const asref = tryref(r.name)
      if (undefined !== asref && isref[asref] && -1 === from.indexOf(asref)) {
        from.push(asref)
      }
      for (const p of from) {
        if (p !== n.ref && -1 === out.indexOf(p)) out.push(p)
      }
    }
    edges[n.ref] = out.sort()
  }

  const WHITE = 0, GREY = 1, BLACK = 2
  const colour: { [ref: string]: number } = {}
  for (const n of nodes) colour[n.ref] = WHITE

  for (const start of Object.keys(edges).sort()) {
    if (WHITE !== colour[start]) continue
    const path: string[] = []
    const stack: { ref: string, i: number }[] = [{ ref: start, i: 0 }]
    colour[start] = GREY
    path.push(start)

    while (0 < stack.length) {
      const top = stack[stack.length - 1]
      const next = edges[top.ref][top.i++]
      if (undefined === next) {
        colour[top.ref] = BLACK
        stack.pop()
        path.pop()
        continue
      }
      if (GREY === colour[next]) {
        // Report the cycle itself, not the walk that found it.
        return path.slice(path.indexOf(next)).concat([next])
      }
      if (BLACK === colour[next]) continue
      colour[next] = GREY
      path.push(next)
      stack.push({ ref: next, i: 0 })
    }
  }
  return null
}

/** Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
export function checkcycle(nodes: Node[]): void {
  const cycle = dependencycycle(nodes)
  if (null != cycle) {
    fail('plugin_dependency_cycle',
      'requirements cycle: ' + cycle.join(' -> '), { cycle })
  }
}
