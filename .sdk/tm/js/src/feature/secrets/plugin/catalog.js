// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/catalog.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1).
 *
 * A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key — so a malformed shape fails once, and in the same
 * place everywhere (§9.4). */

'use strict'

const { fail } = require('./types')
const { checkname } = require('./ref')
const { checkshape } = require('./config')

function makecatalog(defs) {
  const map = {}

  const add = (def) => {
    if (!def || !checkname(def.name)) {
      fail('plugin_definition_name', 'invalid definition name: ' + (def && def.name))
    }
    // Validate the shape HERE. Deferring it to resolution time means a
    // malformed shape surfaces at a different moment in every host that
    // loads it, which is the divergence the stated domain exists to
    // prevent.
    if (def.shape) checkshape(def.shape)
    map[def.name] = def
  }

  for (const d of defs || []) add(d)

  return {
    add,
    get: (name) => map[name],
    has: (name) => undefined !== map[name],
    names: () => Object.keys(map).sort(),
  }
}

module.exports = { makecatalog }
