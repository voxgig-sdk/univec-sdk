// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/FeatureHost.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { Definition } from './Catalog'
import { PointSpec } from './Host'

export const SDK_HOOKS = [
  'PostConstruct',
  'PostConstructEntity',
  'SetData',
  'GetData',
  'GetMatch',
  'PreTarget',
  'PreSpec',
  'PreRequest',
  'PreResponse',
  'PreResult',
  'PostOperation',
]

export const STATION_HOOKS = ['PrePoint', 'PreDone', 'PreUnexpected']

export const REQUEST_POINT = 'request'

export type BridgeOptions = {
  hooks?: string[]
  replace?: string[]
  /** The SDK's REAL ctx. A feature's `init` may read `ctx.client`,
   * `ctx.utility.log` or anything else the SDK hands it, and a
   * synthetic object with one property would either give it the wrong
   * client or fail on a missing utility. The bridge layers its
   * `fetcher` trap ON TOP of this rather than replacing it. */
  ctx?: any
}

export function featurepoints(
  fetcher: (...args: any[]) => any, options?: BridgeOptions
): { [point: string]: PointSpec } {
  const opts = options || {}
  const points: { [point: string]: PointSpec } = {}

  for (const h of SDK_HOOKS.concat(STATION_HOOKS).concat(opts.hooks || [])) {
    if (undefined === points[h]) { points[h] = { kind: 'hook' } }
  }
  for (const r of opts.replace || []) {
    points[r] = { kind: 'provider' }
  }
  points[REQUEST_POINT] = { kind: 'chain', base: fetcher }
  return points
}

type Captured = {
  wrap?: (...args: any[]) => any
  inner: any
}

function makectx(base: any, captured: Captured, options: any): any {
  const source = (base && base.utility) || {}
  const utility: any = {}
  for (const k of Object.keys(source)) { utility[k] = source[k] }
  Object.defineProperty(utility, 'fetcher', {
    enumerable: true,
    configurable: true,
    get: () => captured.inner,
    set: (fn: any) => { captured.wrap = fn },
  })
  return { ...base, utility, options }
}

export type FeatureClass = {
  new(...args: any[]): any
}

export function featuredefinition(
  name: string, Feature: FeatureClass, options?: BridgeOptions
): Definition {
  const opts = options || {}
  const seams = opts.replace || []
  // DEDUPLICATED. A caller naming a hook the core set already has —
  // easy to do, since `extra` is "what this SDK's features declare" and
  // a feature may well declare a core one — would otherwise bind the
  // same method twice and fire it twice on one `emit`.
  const hooknames: string[] = []
  for (const h of SDK_HOOKS.concat(STATION_HOOKS).concat(opts.hooks || [])) {
    if (-1 === hooknames.indexOf(h) && -1 === seams.indexOf(h)) {
      hooknames.push(h)
    }
  }

  return {
    name,

    define: (inst: any) => {
      const feature: any = new (Feature as any)()

      if (null != feature.name && feature.name !== name) {
        const err: any = new Error(
          'plugin/plugin_definition_name: feature name does not match the ' +
          'definition it was registered as: ' + feature.name + ' vs ' + name)
        err.code = 'plugin_definition_name'
        throw err
      }

      const captured: Captured = { inner: undefined }

      let current: any = null
      captured.inner = (...args: any[]) =>
        null == current ? undefined : current(...args)

      const ctx = makectx(
        { client: inst, ...(opts.ctx || {}), feature }, captured, inst.options)

      if ('function' === typeof feature.init) {
        feature.init(ctx, inst.options)
      }

      for (const h of hooknames) {
        if ('function' !== typeof feature[h]) { continue }
        inst.bind(h, (...args: any[]) => feature[h](...args))
      }

      for (const r of seams) {
        if ('function' !== typeof feature[r]) { continue }
        inst.bind(r, (...args: any[]) => feature[r](...args))
      }

      // ...and the transport wrap, if the feature took one, is a chain
      // binding. THIS IS THE REVERSIBILITY: sdkgen assigns the slot and
      // can never put it back; a binding comes out when the instance
      // deactivates, with no cooperation from the feature.
      if ('function' === typeof captured.wrap) {
        inst.bind(REQUEST_POINT, (next: any, ...args: any[]) => {
          current = next
          return (captured.wrap as any)(...args)
        })
      }

      inst.export('feature', feature)
      if (null != feature.version) {
        inst.export('version', feature.version)
      }

      inst.state.feature = feature
    },

    activate: (inst: any) => {
      const feature: any = inst && featureof(inst)
      if (feature && 'function' === typeof feature.activate) {
        feature.activate()
      }
    },

    deactivate: (inst: any) => {
      const feature: any = inst && featureof(inst)
      if (feature && 'function' === typeof feature.deactivate) {
        feature.deactivate()
      }
    },

    close: (inst: any) => {
      const feature: any = inst && featureof(inst)
      if (feature && 'function' === typeof feature.close) {
        feature.close()
      }
    },
  }
}

function featureof(inst: any): any {
  return inst.state && inst.state.feature
}
