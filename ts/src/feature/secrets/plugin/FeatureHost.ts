// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/FeatureHost.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The sdkgen bridge (§17.2, P3 item 2).
 *
 * THE DELIVERABLE IS A BRIDGE THAT RUNS AN UNMODIFIED SDKGEN FEATURE
 * CLASS AS A PLUGIN, proving the two vocabularies map — and leaving
 * whether sdkgen's generated code adopts the model as a separate,
 * sdkgen-side decision with its own cost across 23 template trees.
 *
 * A generated SDK is not natively a host. Wrapping one in `inst.host()`
 * directly would be a host-shaped object around a non-host, so the
 * INNER HOST IS THE BRIDGE, NOT THE SDK: it declares points for the
 * SDK's hook vocabulary and its `request` chain, and a feature's own
 * method names become its bindings.
 *
 * WHAT THE BRIDGE BUYS, IN ONE SENTENCE: sdkgen can activate a feature
 * and cannot deactivate one, because its transport wrap is an
 * irreversible assignment — `ctx.utility.fetcher = wrapped` — and its
 * hook methods are read off a fixed array. Both become bindings here,
 * and bindings come out.
 *
 *
 * THIS FILE IS OUTSIDE THE PORTABILITY BUDGET, DELIBERATELY, AND IT IS
 * THE ONLY ONE.
 *
 * `typescript/AGENTS.md` forbids dynamic property interception, and the
 * `utility.fetcher` getter/setter below is exactly that. The budget
 * governs the PORTABLE LIBRARY — the thing twenty languages implement
 * from one corpus — and it is not negotiable there.
 *
 * A BRIDGE TO SDKGEN CANNOT BE PORTED AND IS NOT MEANT TO BE. sdkgen
 * generates SDKs in 23 languages, each feature written in that
 * language's idiom; a Go SDK's feature does not assign
 * `ctx.utility.fetcher`, so there is nothing for a Go translation of
 * this file to intercept. Each language that wants the bridge writes
 * its own, against its own generated code, and the thing they share is
 * the plugin model underneath — not this mechanism.
 *
 * Said here because the contradiction is otherwise live and invisible:
 * `Config.ts` cites the same budget as the reason `apply` refills an
 * options map instead of installing a getter. That reasoning is correct
 * and unchanged; this file is a different kind of thing. */

import { Definition } from './Catalog'
import { PointSpec } from './Host'

/** sdkgen's declared hook vocabulary (`main.kit.feature.&.hook` in
 * `model/sdkgen.aon`).
 *
 * §17.2 says "13 hook points, named exactly as today". The model
 * declares ELEVEN; the three station's own feature adds — `PrePoint`,
 * `PreDone`, `PreUnexpected` — are declared by that feature rather than
 * by the core, because `hook: &:` admits any name. So the count depends
 * on which features are installed, which is why the bridge takes the
 * extra names rather than this list pretending to be closed.
 * Recorded in doc/plan/handover.md rather than silently resolved. */
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

/** The hooks sdkgen-station's feature declares beyond the core set.
 * Named here so the bridge's default vocabulary covers the one feature
 * this repo's first consumer actually ships. */
export const STATION_HOOKS = ['PrePoint', 'PreDone', 'PreUnexpected']

/** The one chain point: the SDK's transport. Its base is
 * `utility.fetcher`, which is exactly what a wrapping feature captures
 * and replaces today. */
export const REQUEST_POINT = 'request'

/** What a particular SDK adds to the default vocabulary.
 *
 * All three fields exist because §17.2's mapping is stated in terms of
 * a specific SDK's declarations, and a bridge that hard-coded them
 * would be right for exactly one SDK. */
export type BridgeOptions = {
  /** Hook names this SDK's installed features declare beyond the core
   * set. */
  hooks?: string[]
  /** §17.2: "`provider` points for the seams `__replace__` currently
   * serves." A replacement seam is a PROVIDER point and not a chain —
   * at most one implementation wins, the losers are visible, and the
   * host keeps a default — which is precisely what `__replace__` means
   * and what a chain cannot express. */
  replace?: string[]
  /** The SDK's REAL ctx. A feature's `init` may read `ctx.client`,
   * `ctx.utility.log` or anything else the SDK hands it, and a
   * synthetic object with one property would either give it the wrong
   * client or fail on a missing utility. The bridge layers its
   * `fetcher` trap ON TOP of this rather than replacing it. */
  ctx?: any
}

/** Points for a bridge host: every hook name as a `hook` point, each
 * replacement seam as a `provider` point, plus `request` as a `chain`
 * whose base is the SDK's own fetcher. */
export function featurepoints(
  fetcher: (...args: any[]) => any, options?: BridgeOptions
): { [point: string]: PointSpec } {
  const opts = options || {}
  const points: { [point: string]: PointSpec } = {}

  for (const h of SDK_HOOKS.concat(STATION_HOOKS).concat(opts.hooks || [])) {
    if (undefined === points[h]) { points[h] = { kind: 'hook' } }
  }
  for (const r of opts.replace || []) {
    // A seam declared BOTH ways is a contradiction in the SDK's own
    // declarations, and the provider reading wins loudly rather than
    // the map's iteration order deciding.
    points[r] = { kind: 'provider' }
  }
  points[REQUEST_POINT] = { kind: 'chain', base: fetcher }
  return points
}

/** The ctx an sdkgen feature's `init` expects.
 *
 * `utility.fetcher` is a GETTER/SETTER PAIR rather than a field, and
 * that is the whole trick: a feature that writes
 * `ctx.utility.fetcher = wrapped` is expressing a chain binding, and
 * the bridge records it as one instead of letting it overwrite the
 * slot. Reading it back returns the marker the feature should call,
 * which is `next` — so the feature's own `const inner = utility.fetcher`
 * still gives it something to call through to.
 *
 * This is the single place the irreversible assignment becomes
 * reversible; everything else about the feature is untouched. */
type Captured = {
  wrap?: (...args: any[]) => any
  inner: any
}

function makectx(base: any, captured: Captured, options: any): any {
  // Layer onto the SDK's REAL utility, so a feature reading anything
  // else off it still finds what the SDK put there.
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

/** Turn an sdkgen `Feature` class into a plugin definition, MECHANICALLY
 * (§17.2):
 *
 *  - `name` and `version` come off the instance, as today;
 *  - `init(ctx, options)` runs in `define`, where reading options and
 *    declaring bindings belong;
 *  - a method named after a hook point IS a binding to that point —
 *    "a feature's method names are its bindings";
 *  - a method named after a replacement seam is a `provider` binding;
 *  - an assignment to `ctx.utility.fetcher` becomes a `request` chain
 *    binding rather than an irreversible overwrite.
 *
 * The feature class is not modified, subclassed or inspected beyond its
 * own public surface. That is the claim being proved.
 *
 *
 * WHAT "AND DEACTIVATES IT" CLAIMS, EXACTLY.
 *
 * §17.2 says `init` "splits into `define` (read options, declare
 * bindings) and `activate` (capture)". THAT SPLIT IS SDKGEN'S TO MAKE.
 * An unmodified feature has one `init` and no teardown method, so the
 * bridge runs `init` in `define` and there is nothing it could call to
 * undo a side effect `init` performed — a connection opened there stays
 * open, and no amount of bridging changes that.
 *
 * So the claim is precisely: THE FEATURE'S BINDINGS BECOME REVERSIBLE.
 * Its hooks stop firing and its transport wrap leaves the chain, with
 * no cooperation from the feature — which is the thing sdkgen cannot do
 * at all, because it assigns the slot and has nowhere to put the old
 * value back. It is not a claim that arbitrary `init` side effects are
 * undone.
 *
 * A feature that DOES carry `activate` / `deactivate` / `close` methods
 * gets them wired below, which is the same mapping applied to the
 * methods §17.2 expects an adopting sdkgen to add. */
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

      // THE DEFINITION NAME AND THE FEATURE'S OWN NAME MUST AGREE.
      // §17.2 maps a feature's `name` to the definition's, so a caller
      // passing a different string leaves configuration addressed by
      // the SDK's feature name unable to resolve the definition, while
      // the exported object reports a third identity. Loud, because the
      // failure it prevents is silent.
      if (null != feature.name && feature.name !== name) {
        const err: any = new Error(
          'plugin/plugin_definition_name: feature name does not match the ' +
          'definition it was registered as: ' + feature.name + ' vs ' + name)
        err.code = 'plugin_definition_name'
        throw err
      }

      const captured: Captured = { inner: undefined }

      // `inner` is what the feature reads back from `utility.fetcher`.
      // In a chain the value to call through to is `next`, which is not
      // known until the binding runs — so the feature is handed a
      // trampoline that forwards to whatever `next` is at call time.
      //
      // ONE SHARED SLOT, AND THE LIMIT IS REAL. An sdkgen feature
      // stashes `inner` once, at init; §6.2 names that exact pattern as
      // "a bug the host cannot prevent" and declines to pretend
      // otherwise. Sequential and nested calls are correct — the
      // binding sets `current` immediately before the wrap runs — but
      // if the wrap awaits and a SECOND request begins before it
      // resumes, both share this slot and the resumed wrap calls
      // through the second request's chain.
      //
      // Restoring the previous value in a `finally` makes it worse, not
      // better: the finally runs when the wrap returns its promise,
      // before the feature ever calls `inner`. Fixing it properly needs
      // either a per-invocation channel the feature would have to be
      // modified to accept — which is the thing this bridge exists to
      // avoid — or async-context storage, which the portability budget
      // forbids and which does not exist in most of the 23 languages.
      // Stated rather than papered over.
      let current: any = null
      captured.inner = (...args: any[]) =>
        null == current ? undefined : current(...args)

      const ctx = makectx(
        { client: inst, ...(opts.ctx || {}), feature }, captured, inst.options)

      // The SDK calls `init(ctx, options)`; so do we, unchanged.
      if ('function' === typeof feature.init) {
        feature.init(ctx, inst.options)
      }

      // A method named after a hook point IS a binding to it.
      for (const h of hooknames) {
        if ('function' !== typeof feature[h]) { continue }
        inst.bind(h, (...args: any[]) => feature[h](...args))
      }

      // ...and a method named after a replacement seam is a PROVIDER
      // binding (§17.2), which is what `__replace__` means: at most one
      // wins, the losers are visible, and the host keeps a default.
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

      // ...and the instance's OWN state, which is where the three later
      // callbacks read it from. The export is the public handle; it is
      // not a channel back to the definition, because §11 hides the
      // exports of a `failed` instance — and `unload` on a failed
      // instance still runs `close` (§5.2). Reading the feature back
      // through `exports` therefore lost it in exactly the case where a
      // feature holding a connection most needs its `close` to run.
      inst.state.feature = feature
    },

    // §17.2's `activate` (capture) half, for a feature that has one.
    // Today's sdkgen features do not — which is why the bridge's claim
    // is about bindings and not about side effects — but a feature that
    // grows the methods §17.2 expects gets them called, in the phase
    // the model puts them in.
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

/** The feature object `define` built, read back from the instance's own
 * state rather than closed over, so the three later callbacks do not
 * each need their own capture.
 *
 * NOT from `exports`. §11 hides a `failed` instance's exports, and
 * `unload` on a failed instance still runs `close` — so an exports read
 * returned undefined precisely when a feature holding a connection
 * needed its `close` to run. `state` is the instance's own and survives
 * every status. */
function featureof(inst: any): any {
  return inst.state && inst.state.feature
}
