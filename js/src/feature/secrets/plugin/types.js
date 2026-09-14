// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/types.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Shared types. Deliberately small: the design's §19 budget says the
 * library owns naming, configuration, lifecycle, ordering, binding and
 * teardown, and nothing else.
 *
 * JavaScript is the canonical's own language with the types removed, so
 * this port is the one place a divergence would be pure carelessness
 * rather than translation. What it does NOT get for free is the
 * canonical's compile-time shape checking, which is why the corpus runs
 * here exactly as it does in a language that shares nothing. */

'use strict'

/** §5.1's seven statuses, and no more. A port that adds an eighth is
 * diverging. `loading` and `closing` are observable only from inside a
 * callback or from another thread. */
const STATUSES = [
  'declared', 'loaded', 'pending', 'live', 'failed', 'loading', 'closing',
]

/** §12's detail fields, IN THIS FIXED ORDER.
 *
 * The order is part of the contract, not a formatting preference. An
 * earlier draft named six fields while other sections promised
 * diagnostics that had nowhere to go, which would have left each port
 * inventing its own order and breaking message parity. */
const DETAIL_ORDER = [
  'host', 'ref', 'name', 'tag', 'point', 'key', 'capability',
  'range', 'version', 'match', 'candidates', 'cycle', 'holders',
  'refs', 'path', 'cause',
]

/** `plugin/<code>: <text> [<key>=<value> …]`
 *
 * Values render as COMPACT JSON, so a value containing a space or a
 * bracket cannot break the parse, and a list renders as a JSON array.
 * The bracket is absent entirely when no field applies. */
function formaterror(code, text, details) {
  const d = details || {}
  const parts = []
  for (const k of DETAIL_ORDER) {
    if (undefined === d[k]) continue
    parts.push(k + '=' + JSON.stringify(d[k]))
  }
  const tail = 0 === parts.length ? '' : ' [' + parts.join(' ') + ']'
  return 'plugin/' + code + ': ' + text + tail
}

/** Every error carries a §12 code. Ports compare by CODE and never by
 * message: wording is a port's own business, and pinning the words would
 * make every translation a corpus change. The FORMAT, however, is
 * pinned — a parseable message is what makes a log searchable across
 * twenty languages. */
class PluginError extends Error {
  constructor(code, text, details) {
    super(formaterror(code, text, details))
    this.name = 'PluginError'
    this.code = code
    this.text = text
    this.details = details || {}
  }
}

function fail(code, text, details) {
  throw new PluginError(code, text, details)
}

/** The §12 code of an error, or '' for one this library did not raise.
 * The corpus compares by code, so the driver needs one place that knows
 * how to read it. */
function codeof(err) {
  return (err && err.code) || ''
}

module.exports = {
  STATUSES, DETAIL_ORDER, formaterror, PluginError, fail, codeof,
}
