// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/graph.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Whole-graph resolution (§11.4) — a phase, not a discovery.
 *
 * "Activate, and wait in `pending` if you must" is correct and, on its
 * own, produces a terrible experience: apply twenty instances against a
 * registry missing one thing and you get NINETEEN pending rows and no
 * statement of what is actually wrong.
 *
 * `resolvegraph` is a PURE FUNCTION of the registry and the intended
 * activation set. No callbacks run, no state changes, nothing is
 * touched. It answers for the whole graph at once which instances can be
 * live, and for each blocked one THE SPECIFIC REQUIREMENT that is unmet,
 * and why.
 *
 * The failure mode being designed against is a famous one: OSGi's
 * resolver is correct and its diagnostics are legendarily unusable. A
 * resolver that says "blocked" without saying WHY has moved the problem
 * rather than solved it, so `why` is part of the contract and the corpus
 * pins its shape. */

'use strict'

const { resolvecapability, matchvalue } = require('./capability')
const { satisfies } = require('./version')
const { tryref } = require('./ref')

function resolvegraph(nodes) {
  const byref = {}
  for (const n of nodes) byref[n.ref] = n

  const resolved = new Set()
  const blocked = {}

  // Fixed point: a node resolves when every mandatory requirement is met
  // by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
  // makes a provider that is itself blocked propagate, rather than each
  // node being judged against the raw registry.
  let moved = true
  while (moved) {
    moved = false
    for (const n of nodes) {
      if (resolved.has(n.ref)) continue
      if (null == firstunmet(n, byref, resolved)) { resolved.add(n.ref); moved = true }
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

/** The FIRST unmet requirement, with the most specific explanation
 * available. Order matters: "no provider at all" and "a provider at the
 * wrong version" are different problems and a reader must not have to
 * guess which they have. */
function firstunmet(n, byref, resolved) {
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
        .filter((c) => undefined === c.provides.version ||
          !satisfies(c.provides.version, req.range))
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
          // The same recursive partial match `matches` applies, so a
          // nested requirement that FAILED the selection is also the one
          // the diagnosis names (§11.4).
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

function candidates(byref, name) {
  const out = []
  // A NODE SATISFIES ITS OWN REF (§11.1), and the graph learned it here.
  // Considering only declared capabilities made `resolve()` answer
  // `absent` about a provider sitting right there and live — §11.4's job
  // is explaining the graph the runtime reconciles, and it was
  // explaining a different one.
  const asref = tryref(name)
  for (const ref of Object.keys(byref).sort()) {
    const n = byref[ref]
    // The ref match WINS OUTRIGHT for that node, as at runtime: one
    // candidate, not two, for a node both named `b` and providing `b`.
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

module.exports = { resolvegraph }
