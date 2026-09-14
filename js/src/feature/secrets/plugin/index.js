// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/index.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The canonical surface `make parity` checks (AGENTS.md §4). Small on
 * purpose (§19): everything else is methods on the host and instance
 * types, because a library that grows a second public entry point per
 * feature is a library twenty ports pay for twice. */

'use strict'

const { makehost } = require('./host')
const { makecatalog } = require('./catalog')
const { parseref, formatref, checkname, checktag, canonref } = require('./ref')
const { normalizeconfig, resolveoptions, checkshape } = require('./config')
const { resolveorder } = require('./order')
const { resolvecandidates, resolvefrom } = require('./resolve')
const { applyenv, encoderef } = require('./env')
const { parserange, parseversion, satisfies } = require('./version')
const { resolvecapability, matches } = require('./capability')
const { resolvegraph } = require('./graph')
const { emit, compose, provider } = require('./point')
const { resolveexport } = require('./export')
const { PluginError, formaterror, codeof, DETAIL_ORDER, STATUSES } = require('./types')

module.exports = {
  makehost, makecatalog,
  parseref, formatref, checkname, checktag, canonref,
  normalizeconfig, resolveoptions, checkshape,
  resolveorder, resolvecandidates, resolvefrom,
  applyenv, encoderef,
  parserange, parseversion, satisfies,
  resolvecapability, matches, resolvegraph,
  emit, compose, provider, resolveexport,
  PluginError, formaterror, codeof, DETAIL_ORDER, STATUSES,
}
