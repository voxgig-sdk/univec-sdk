// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Graph.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import {
  Provided, Required, Candidate, resolvecapability, matchvalue,
} from './Capability'
import { satisfies } from './Version'
import { tryref } from './Ref'

export type Node = {
  ref: string
  pos: number
  provides?: Provided[]
  requires?: Required[]
}

export type Blocked = {
  ref: string
  /** The capability name that could not be satisfied. */
  unmet: string
  why: Why
}

export type Why =
  | { kind: 'absent' }
  | { kind: 'version', range: string, found: string[] }
  | { kind: 'match', failing: string, want: any, found: any }
  | { kind: 'blocked', chain: string[] }

export type Resolution = { resolved: string[], blocked: Blocked[] }

export function resolvegraph(nodes: Node[]): Resolution {
  const byref: { [ref: string]: Node } = {}
  for (const n of nodes) byref[n.ref] = n

  const resolved = new Set<string>()
  const blocked: { [ref: string]: Blocked } = {}

  let moved = true
  while (moved) {
    moved = false
    for (const n of nodes) {
      if (resolved.has(n.ref)) continue
      const why = firstunmet(n, byref, resolved)
      if (null == why) { resolved.add(n.ref); moved = true }
    }
  }

  for (const n of nodes) {
    if (resolved.has(n.ref)) continue
    const why = firstunmet(n, byref, resolved)
    if (null != why) blocked[n.ref] = why
  }

  return {
    resolved: Array.from(resolved).sort(),
    blocked: Object.keys(blocked).sort().map((r) => blocked[r]),
  }
}

function firstunmet(
  n: Node,
  byref: { [ref: string]: Node },
  resolved: Set<string>
): Blocked | null {
  for (const req of n.requires || []) {
    if (req.optional) continue

    const all = candidates(byref, req.name)
    if (0 === all.length) {
      return { ref: n.ref, unmet: req.name, why: { kind: 'absent' } }
    }

    const ok = resolvecapability(req, all)
    if (0 < ok.length) {
      // A provider exists and matches — but if none of them is itself
      // resolved, this node is blocked BEHIND it, and the chain is the
      // useful answer rather than "unmet".
      const live = ok.filter((c) => resolved.has(c.ref))
      if (0 < live.length) continue
      return {
        ref: n.ref, unmet: req.name,
        why: { kind: 'blocked', chain: ok.map((c) => c.ref).sort() },
      }
    }

    // Providers exist and none matched. Say which test failed.
    if (undefined !== req.range) {
      const versions = all
        .filter((c) => undefined === c.provides.version || !satisfies(c.provides.version, req.range as string))
        .map((c) => c.provides.version || '(none)')
      if (0 < versions.length) {
        return {
          ref: n.ref, unmet: req.name,
          why: { kind: 'version', range: req.range, found: versions.sort() },
        }
      }
    }

    if (undefined !== req.match) {
      for (const c of all) {
        const attrs = c.provides.attrs || {}
        for (const k of Object.keys(req.match).sort()) {
          if (!(k in attrs) || !matchvalue(req.match[k], attrs[k])) {
            return {
              ref: n.ref, unmet: req.name,
              why: {
                kind: 'match', failing: k,
                want: req.match[k],
                found: undefined === attrs[k] ? null : attrs[k],
              },
            }
          }
        }
      }
    }

    return { ref: n.ref, unmet: req.name, why: { kind: 'absent' } }
  }
  return null
}

function candidates(byref: { [ref: string]: Node }, name: string): Candidate[] {
  const out: Candidate[] = []
  const asref = tryref(name)
  for (const ref of Object.keys(byref).sort()) {
    const n = byref[ref]
    if (ref === asref) {
      out.push({ ref: n.ref, pos: n.pos, provides: { name } })
      continue
    }
    for (const p of n.provides || []) {
      if (p.name === name) out.push({ ref: n.ref, pos: n.pos, provides: p })
    }
  }
  return out
}
