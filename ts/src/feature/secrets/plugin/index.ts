// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/index.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The canonical surface `make parity` checks (AGENTS.md §4). Small on
 * purpose (§19): everything else is methods on the host and instance
 * types, because a library that grows a second public entry point per
 * feature is a library twenty ports pay for twice. */

export { makehost } from './Host'
export { makecatalog } from './Catalog'
export { parseref, formatref, checkname, checktag, canonref, tryref } from './Ref'
export { normalizeconfig, resolveoptions, checkshape } from './Config'
export { resolveorder } from './Order'
export { resolvecandidates, resolvefrom } from './Resolve'
export { applyenv, encoderef } from './Env'
export { parserange, parseversion, satisfies } from './Version'
export { resolvecapability, matches } from './Capability'
export { resolvegraph } from './Graph'
export { emit, compose, provider } from './Point'
export { resolveexport } from './Export'
export {
  REQUEST_POINT, SDK_HOOKS, STATION_HOOKS, featuredefinition, featurepoints,
} from './FeatureHost'
export type { FeatureClass } from './FeatureHost'

export { PluginError } from './Types'
export type { Ref, Status, Instance, OrderRef, OrderSpec, OrderBlock, Normalized } from './Types'
export type { Definition, Catalog } from './Catalog'
export type { Binding, Pin } from './Order'
export type { Host, HostOptions, PointSpec } from './Host'
export type { Source } from './Resolve'
export type { EnvInput, EnvResult } from './Env'
export type { Range } from './Version'
export type { Provided, Required, Candidate } from './Capability'
export type { Node, Blocked, Why, Resolution } from './Graph'
export type { Kind, Mode, Spec, Bound } from './Point'
export type { Exported } from './Export'
