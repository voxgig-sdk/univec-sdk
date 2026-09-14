// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/env.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Environment overrides (§9.5) — level 7 of the ladder.
 *
 * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
 *
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 *
 * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
 * OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
 * `_`. But `_` is legal in a name and in a tag, and the mapping folds
 * case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
 *
 * Rather than restrict a grammar the rest of the stack already uses, the
 * host DETECTS THE COLLISION: it encodes every ref it holds, and a key
 * two refs claim is `plugin_env_ambiguous`, naming both. */

'use strict'

const { fail } = require('./types')
const { canonref, parseref } = require('./ref')

const PREFIX = 'VOXGIG_PLUGIN_'

/** `retry$fast` -> `RETRY__FAST`. */
function encoderef(ref) {
  return ref.replace(/\$/g, '__').replace(/\./g, '_').toUpperCase()
}

function applyenv(input) {
  const env = (input && input.env) || {}
  const refs = ((input && input.refs) || []).map(canonref)
  const reserved = (input && input.reserved) || []
  const out = { options: {}, active: [], inactive: [] }

  // Encode every ref the host holds, and refuse a key that two of them
  // claim. Done up front so the collision is reported even when no
  // environment variable exercises it — a latent ambiguity is still an
  // ambiguity, and finding it at deploy time is the failure this exists
  // to prevent.
  const byencoded = {}
  for (const r of refs) {
    const e = encoderef(r)
    ;(byencoded[e] || (byencoded[e] = [])).push(r)
  }
  for (const e of Object.keys(byencoded).sort()) {
    if (1 < byencoded[e].length) {
      const pair = byencoded[e].slice().sort()
      fail('plugin_env_ambiguous',
        'refs collide in the environment encoding as ' + e + ': ' + pair.join(', '),
        { encoded: e, refs: pair })
    }
  }

  // Longest encoded ref first, so `retry$fast` wins over `retry` on
  // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
  const encoded = Object.keys(byencoded).sort((a, b) => b.length - a.length)

  for (const key of Object.keys(env).sort()) {
    if (!key.startsWith(PREFIX)) continue
    const rest = key.substring(PREFIX.length)

    if ('PROFILE' === rest) { out.profile = env[key]; continue }

    if ('ACTIVE' === rest || 'INACTIVE' === rest) {
      for (const r of split(env[key])) {
        const c = canonref(r)
        // The reservation covers EVERY input layer (§9.1).
        // VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
        // config file, and INACTIVE has the final word — so guarding
        // documents alone would leave the one lever this mechanism
        // exists to deny wide open.
        checkreserved(c, reserved)
        if ('ACTIVE' === rest) out.active.push(c)
        else out.inactive.push(c)
      }
      continue
    }

    const enc = encoded.find((e) => rest === e || rest.startsWith(e + '_'))
    if (undefined === enc) continue      // not for any ref this host holds
    const ref = byencoded[enc][0]
    checkreserved(ref, reserved)

    if (rest === enc) continue           // a ref with no path sets nothing
    const path = rest.substring(enc.length + 1).toLowerCase().split('_')

    let node = out.options[ref] || (out.options[ref] = {})
    for (let i = 0; i < path.length - 1; i++) {
      node = node[path[i]] || (node[path[i]] = {})
    }
    node[path[path.length - 1]] = parsevalue(env[key])
  }

  return out
}

function split(v) {
  return String(v).split(',').map((s) => s.trim()).filter((s) => 0 < s.length)
}

function checkreserved(ref, reserved) {
  if (0 === reserved.length) return
  if (-1 !== reserved.indexOf(parseref(ref).name)) {
    fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
  }
}

/** Values parse as JSON, FALLING BACK TO STRING — so `8080` is a number,
 * `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
 * looks like rather than a parse error. */
function parsevalue(v) {
  try { return JSON.parse(v) }
  catch (err) { return v }
}

module.exports = { applyenv, encoderef }
