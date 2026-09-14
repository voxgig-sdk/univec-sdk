// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/capability.js)
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

'use strict'

const { satisfies } = require('./version')

/** Rank the matching live providers and return them best-first:
 * highest `version`, then LOWEST `priority` (default 0), then
 * declaration position `pos` ascending.
 *
 * `priority` is a field on the capability rather than §7's `order` band,
 * because bands live on POINT BINDINGS: a provider may have several
 * bindings with different bands, or none at all, so a rank reaching for
 * one would be undefined in the common case.
 *
 * Without a total rank, "any provider satisfies" is true of the GRAPH
 * and useless to the PLUGIN — two ports could bind different `store`
 * instances, both resolve green, and behave differently, which is
 * precisely the divergence a shared corpus exists to catch. */
function resolvecapability(req, candidates) {
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

function matches(req, prov) {
  if (req.name !== prov.name) return false

  if (undefined !== req.range) {
    if (undefined === prov.version) return false
    if (!satisfies(prov.version, req.range)) return false
  }

  // `match` is checked against the provider's `attrs`, key by key. A key
  // the provider does not carry is a miss, not a pass: a requirement
  // asking for `transactional: true` must not be satisfied by a provider
  // that never said.
  if (undefined !== req.match) {
    const attrs = prov.attrs || {}
    for (const k of Object.keys(req.match)) {
      if (!(k in attrs)) return false
      if (!matchvalue(req.match[k], attrs[k])) return false
    }
  }

  return true
}

/** PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
 *
 * §11.1 defines `match` as "a partial match against `attrs`, with
 * exactly the semantics voxgig/struct and the omni corpus already define
 * for `match` — every leaf in the requirement must be present and equal
 * in the capability, keys not mentioned are not checked."
 *
 * `===` here is not incidental: EQUALITY IS BY JSON TYPE AS WELL AS
 * VALUE, so `transactional: 1` does not satisfy `transactional: true`.
 * Half the ports are written in languages whose default comparison says
 * otherwise, and `capability/match` pins it for all of them.
 *
 * A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset. */
function matchvalue(want, got) {
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

function isMap(v) {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}

function compare(a, b) {
  const pa = a.split('.').map(Number)
  const pb = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    const x = pa[i] || 0, y = pb[i] || 0
    if (x !== y) return x < y ? -1 : 1
  }
  return 0
}

module.exports = { resolvecapability, matches, matchvalue }
