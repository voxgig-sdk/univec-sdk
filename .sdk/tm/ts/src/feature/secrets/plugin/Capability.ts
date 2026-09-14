// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Capability.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Capabilities (§11.1).
 *
 * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
 * dependency on something that can do the job, and which instance is
 * doing it is exactly the configuration detail a plugin must not care
 * about.
 *
 * But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains. */

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

/** Rank the matching live providers and return them best-first:
 * highest `version`, then LOWEST `priority` (default 0), then
 * declaration position `pos` ascending.
 *
 * `priority` is a field on the capability rather than §7's `order`
 * band, because bands live on POINT BINDINGS: a provider may have
 * several bindings with different bands, or none at all, so a rank
 * reaching for one would be undefined in the common case.
 *
 * Without a total rank, "any provider satisfies" is true of the GRAPH
 * and useless to the PLUGIN — two ports could bind different `store`
 * instances, both resolve green, and behave differently, which is
 * precisely the divergence a shared corpus exists to catch. */
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

  // `match` is checked against the provider's `attrs`, key by key. A
  // key the provider does not carry is a miss, not a pass: a
  // requirement asking for `transactional: true` must not be satisfied
  // by a provider that never said.
  if (undefined !== req.match) {
    const attrs: any = prov.attrs || {}
    for (const k of Object.keys(req.match)) {
      if (!(k in attrs)) return false
      if (!matchvalue((req.match as any)[k], attrs[k])) return false
    }
  }

  return true
}

/** PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
 *
 * §11.1 defines `match` as "a partial match against `attrs`, with
 * exactly the semantics voxgig/struct and the omni corpus already
 * define for `match` — every leaf in the requirement must be present
 * and equal in the capability, keys not mentioned are not checked."
 *
 * THIS FUNCTION IS WHAT "EVERY LEAF" MEANS, and an earlier draft did
 * not have it: the check was `attrs[k] !== req.match[k]`, which for any
 * compound value is JavaScript REFERENCE IDENTITY. A requirement and a
 * capability are declared in different places and are never the same
 * object, so `match: {limits: {max: 5}}` could not be satisfied by any
 * provider at all — including one declaring exactly that. The flat
 * reading is invisible while every corpus entry is scalar, which is why
 * the go port found it and P2 did not.
 *
 * A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
 * "the first two of your three regions" is not something `match` can
 * say, and inventing a spelling for it would be inventing the filter
 * language §11.1 explicitly declines to add. */
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
