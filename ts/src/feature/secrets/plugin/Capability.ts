// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Capability.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { satisfies } from './Version'

export type Provided = {
  name: string
  version?: string
  priority?: number
  attrs?: { [k: string]: any }
}

export type Required = {
  name: string
  range?: string
  match?: { [k: string]: any }
  optional?: boolean
  /** §11.3: `static` restarts the consumer when its SELECTED provider
   * leaves, even though another still matches; `dynamic` says in
   * writing that it can survive the swap. Static is the default because
   * most plugins cannot, and the cost of wrongly assuming they can is a
   * live instance holding a dead reference. */
  policy?: 'static' | 'dynamic'
}

export type Candidate = {
  ref: string
  pos: number
  provides: Provided
}

export function resolvecapability(req: Required, candidates: Candidate[]): Candidate[] {
  const hits = candidates.filter((c) => matches(req, c.provides))
  hits.sort((a, b) => {
    const av = a.provides.version, bv = b.provides.version
    if (av !== bv) {
      if (undefined === av) return 1
      if (undefined === bv) return -1
      const c = compare(bv, av)      // highest version FIRST
      if (0 !== c) return c
    }
    const ap = a.provides.priority || 0
    const bp = b.provides.priority || 0
    if (ap !== bp) return ap - bp    // lowest priority first
    return a.pos - b.pos
  })
  return hits
}

export function matches(req: Required, prov: Provided): boolean {
  if (req.name !== prov.name) return false

  if (undefined !== req.range) {
    if (undefined === prov.version) return false
    if (!satisfies(prov.version, req.range)) return false
  }

  if (undefined !== req.match) {
    const attrs: any = prov.attrs || {}
    for (const k of Object.keys(req.match)) {
      if (!(k in attrs)) return false
      if (!matchvalue((req.match as any)[k], attrs[k])) return false
    }
  }

  return true
}

export function matchvalue(want: any, got: any): boolean {
  if (isMap(want)) {
    if (!isMap(got)) return false
    for (const k of Object.keys(want)) {
      if (!(k in got)) return false
      if (!matchvalue(want[k], got[k])) return false
    }
    return true
  }
  if (Array.isArray(want)) {
    if (!Array.isArray(got) || want.length !== got.length) return false
    for (let i = 0; i < want.length; i++) {
      if (!matchvalue(want[i], got[i])) return false
    }
    return true
  }
  return want === got
}

function isMap(v: any): boolean {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}

function compare(a: string, b: string): number {
  const pa = a.split('.').map(Number)
  const pb = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    const x = pa[i] || 0, y = pb[i] || 0
    if (x !== y) return x < y ? -1 : 1
  }
  return 0
}
