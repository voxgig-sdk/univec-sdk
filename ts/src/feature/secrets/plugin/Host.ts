// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Host.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { Status, Instance, OrderBlock, fail } from './Types'
import { canonref, tryref, parseref, formatref } from './Ref'
import { Catalog, Definition, makecatalog } from './Catalog'
import { resolveorder, Binding, Pin } from './Order'
import { Spec, Bound, Mode, emit as fanout, compose, provider as pickone } from './Point'
import { Exported, resolveexport } from './Export'
import { Provided, Required, Candidate, resolvecapability } from './Capability'
import { normalizeconfig, resolveoptions } from './Config'
import {
  Node, checkcycle, gatesactivation, requirements, restartsonloss,
} from './Depend'

export type PointSpec = Spec

export type HostOptions = {
  catalog?: Catalog
  reserved?: string[]
  keys?: { instance?: string, default?: string }
  defaults?: { [name: string]: any }
  profile?: string
  points?: { [point: string]: PointSpec }
  dependency?: 'restart' | 'hold'
}

type Live = {
  ref: string
  def: Definition
  status: Status
  pos: number
  seq: number
  options: any
  state: any
  order?: OrderBlock
  selected: { [name: string]: string }
  barred?: boolean
  unmet: string[]
  /** Resources the instance scope holds, newest last — unwound in
   * REVERSE, because that is the only order in which teardown mirrors
   * setup (§8.3). */
  scope: (() => void)[]
  /** Declared in `define`, inserted only when activation SUCCEEDS
   * (§8.1). Holding them until then is what makes a failed activate
   * leave nothing behind. */
  bindings: Bound[]
  inner?: any
  /** Declared in `define`, and VISIBLE while merely `loaded` (§11):
   * they are data, and hiding them would make the loaded state useless
   * for introspection. */
  exports: { [key: string]: any }
  provides: Provided[]
}

export type Host = ReturnType<typeof makehost>

export function makehost(options?: HostOptions) {
  const dependency = (options && options.dependency) || 'restart'
  /** Set for the duration of a bulk teardown, so `held` knows this is a
   * coordinated operation rather than an ad-hoc deactivation. */
  let coordinated = false

  const opts = options || {}
  const catalog = opts.catalog || makecatalog()
  const reserved = opts.reserved || []
  const points = opts.points || {}

  const inst: { [ref: string]: Live } = {}
  const log: string[] = []
  /** §14: the lifecycle event record. `seq` distinguishes ONE
   * INCARNATION of stripe$test from the next, which is the whole reason
   * it is not `pos` (§4 rule 4). */
  const events: { ref: string, event: string, seq: number, status: Status }[] = []
  let seqn = 0
  let open = 0
  let intransition = false
  let phase: string | null = null

  // --- observation -------------------------------------------------

  const list = (): { [ref: string]: Status } => {
    const out: { [ref: string]: Status } = {}
    for (const r of Object.keys(inst).sort()) out[r] = inst[r].status
    return out
  }

  const instance = (ref: string): Live | undefined => inst[canonref(ref)]

  const observable = (result?: any) => ({
    status: list(),
    open,
    log: log.slice(),
    result: undefined === result ? null : result,
  })

  // --- the state machine -------------------------------------------

  function guard(): void {
    if (intransition) {
      fail('plugin_reentrant', 'transition attempted from inside a lifecycle callback')
    }
  }

  function need(ref: string): Live {
    const r = canonref(ref)
    const e = inst[r]
    if (!e) fail('plugin_not_loaded', 'no such instance: ' + r, { ref: r })
    return e
  }

  function checkreserved(ref: string): void {
    if (0 === reserved.length) return
    if (-1 !== reserved.indexOf(parseref(ref).name)) {
      fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
    }
  }

  function run(e: Live, cb: keyof Definition, at: string): void {
    const fn = e.def[cb] as any
    log.push(e.ref + ':' + at)
    events.push({ ref: e.ref, event: at, seq: e.seq, status: e.status })
    if ('function' !== typeof fn) return
    intransition = true
    phase = at
    try {
      fn(api(e))
    }
    catch (err: any) {
      if (err && err.code) throw err
      fail('plugin_' + at + '_failed',
        e.ref + ' raised in ' + at + ': ' + (err && err.message),
        { ref: e.ref, cause: err && err.message })
    }
    finally {
      intransition = false
      phase = null
    }
  }

  function api(e: Live) {
    return {
      ref: e.ref,
      name: parseref(e.ref).name,
      tag: parseref(e.ref).tag,
      options: e.options,
      state: e.state,
      /** Foreign resources the host did not hand out are registered
       * explicitly (§8.3); host calls are recorded automatically. */
      release: (fn: () => void) => {
        // §8.3: "`inst.release` outside `activate` is
        // `plugin_release_scope`". `intransition` is true in `define`
        // too, and a scope entry registered there is never unwound —
        // `unload` on a merely `loaded` instance does not call `unwind`,
        // because a loaded instance is not supposed to hold anything.
        if ('activate' !== phase) {
          fail('plugin_release_scope', 'release called outside activate')
        }
        let done = false
        e.scope.push(() => { if (!done) { done = true; open -= 1; fn() } })
        open += 1
      },
      acquire: (): (() => void) => {
        // §8.1: resources are "acquired during `activate` — the scope's
        // actual job". Same reason as `release` above.
        if ('activate' !== phase) {
          fail('plugin_release_scope', 'acquire called outside activate')
        }
        let done = false
        const rel = () => { if (!done) { done = true; open -= 1 } }
        e.scope.push(rel)
        open += 1
        return rel
      },
      host: () => self,

      bind: (point: string, fn: any, band?: number) => {
        if ('define' !== phase) {
          fail('plugin_bind_scope', 'bind called outside define: ' + point,
            { ref: e.ref, point })
        }
        if (undefined === points[point]) {
          fail('plugin_point_unknown', 'no such point: ' + point, { point })
        }
        e.bindings.push({ ref: e.ref, point, fn, band: band || 0 })
      },

      export: (key: string, value: any) => { e.exports[key] = value },

      capability: (name: string): string | undefined => {
        const req = requirements(e.options).find((r) => r.name === name)
        if (undefined === req) return undefined
        return chosen(e, req, true)
      },

      provides: (p: Provided) => { e.provides.push(p) },

      position: (point: string) => {
        const ranked = order(point)
        const index = ranked.indexOf(e.ref)
        return {
          index,
          count: ranked.length,
          outermost: 0 === index,
          innermost: index === ranked.length - 1,
        }
      },

      /** AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE
       * OWNS THE INNER ONE'S LIFETIME. Registering the teardown in the
       * instance scope is what makes that true rather than aspirational:
       * the inner host closes when the outer instance deactivates, in
       * the same reverse unwind as every other resource. */
      nest: (nestopts?: HostOptions) => {
        if (!intransition) {
          fail('plugin_release_scope', 'nest called outside a lifecycle callback')
        }
        const inner = makehost(nestopts)
        e.scope.push(() => inner.close())
        e.inner = inner
        return inner
      },
    }
  }

  function autotag(name: string): string {
    for (let n = 1; ; n++) {
      const cand = formatref(name, String(n))
      if (undefined === inst[cand]) return cand
    }
  }

  type DeclareSpec = {
    definition?: string, options?: any, order?: OrderBlock,
    pos?: number, tag?: string,
    /** §9.1: "The host declares those instances itself, after the user
     * merge, and always wins." Set ONLY by `hostdeclare`. */
    hostowned?: boolean,
  }

  function declare(ref: string, spec?: DeclareSpec): Live {
    if (spec && '?' === spec.tag) {
      ref = autotag(parseref(canonref(ref)).name)
    }
    const r = canonref(ref)
    if (!(spec && spec.hostowned)) checkreserved(r)
    const s = spec || {}
    const defname = s.definition || parseref(r).name
    const def = catalog.get(defname)
    if (!def) {
      fail('plugin_unknown_definition', 'not in catalog: ' + defname, { name: defname })
    }

    const existing = inst[r]
    if (existing) {
      // §4 rule 1: a pair addresses at most one instance. Re-declaring
      // the SAME definition is the idempotent case; a different one is
      // a duplicate, not a silent overwrite (seneca) and not an
      // impossibility (sdkgen).
      if (existing.def.name !== def.name) {
        fail('plugin_ref_duplicate', 'instance already declared: ' + r, { ref: r })
      }
      return existing
    }

    const e: Live = {
      ref: r, def, status: 'declared',
      pos: undefined === s.pos ? Object.keys(inst).length : s.pos,
      seq: seqn++,
      options: s.options || {},
      state: {}, order: s.order, unmet: [], scope: [],
      bindings: [], exports: {}, provides: [], selected: {},
    }
    inst[r] = e
    return e
  }

  function load(ref: string, spec?: any): Live {
    guard()
    const e = declare(ref, spec)
    if ('declared' !== e.status) return e
    if (spec && spec.options) e.options = spec.options
    try {
      run(e, 'define', 'define')
    }
    catch (err: any) {
      e.status = 'failed'
      throw err
    }
    e.status = 'loaded'

    try { checkcycle(graphnodes()) }
    catch (err: any) {
      e.status = 'failed'
      throw err
    }
    return e
  }

  function graphnodes(): Node[] {
    return Object.keys(inst).sort().map((r) => ({
      ref: r,
      provides: inst[r].provides.map((p) => p.name),
      requires: requirements(inst[r].options),
    }))
  }

  function activate(ref: string): Live {
    guard()
    const e = need(ref)
    if ('live' === e.status) return e
    if ('failed' === e.status) {
      fail('plugin_bad_state', 'instance has failed: ' + e.ref, { ref: e.ref })
    }
    if (e.barred) {
      fail('plugin_inactive', 'instance is barred by active: false: ' + e.ref,
        { ref: e.ref })
    }
    if ('declared' === e.status) load(e.ref)

    if (0 < unmetof(e).length) {
      e.unmet = unmetof(e)
      e.status = 'pending'
      return e
    }

    try {
      run(e, 'activate', 'activate')
    }
    catch (err: any) {
      unwind(e)
      e.status = 'failed'
      throw err
    }
    // §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
    // later question — the cascade, `hold`, `unmet` — reads it back
    // rather than re-ranking, which is what "always-reluctant" means.
    for (const r of requirements(e.options)) chosen(e, r, true)
    e.status = 'live'
    reconcile()
    return e
  }

  function deactivate(ref: string): Live {
    guard()
    const e = need(ref)
    if ('loaded' === e.status || 'declared' === e.status) return e

    if ('failed' === e.status) {
      fail('plugin_bad_state', 'instance has failed: ' + e.ref, { ref: e.ref })
    }

    if ('pending' === e.status) {
      e.status = 'loaded'
      e.unmet = []
      return e
    }

    held(e)
    cascade(e)

    try {
      run(e, 'deactivate', 'deactivate')
    }
    catch (err: any) {
      unwind(e)
      e.status = 'failed'
      throw err
    }
    releasecheck(e, unwind(e))
    e.status = 'loaded'
    reconcile()
    return e
  }

  function unload(ref: string): void {
    guard()
    const e = need(ref)
    if ('live' === e.status || 'pending' === e.status) {
      if ('live' === e.status) {
        held(e)
        cascade(e)
        try {
          run(e, 'deactivate', 'deactivate')
        }
        catch (err: any) {
          unwind(e)
          e.status = 'failed'
          throw err
        }
        releasecheck(e, unwind(e))
      }
      e.status = 'loaded'
    }
    if ('loaded' === e.status || 'failed' === e.status) {
      try { run(e, 'close', 'close') }
      finally { delete inst[e.ref] }
      return
    }
    delete inst[e.ref]
  }

  function ready(ref: string): Live {
    guard()
    const r = canonref(ref)
    if (!inst[r]) declare(r)
    if ('declared' === inst[r].status) load(r)
    return activate(r)
  }

  /** A selection belongs to ONE activation (§11.4). Leaving `live` by
   * any door drops it, so the next activation ranks afresh — keeping it
   * would make a consumer prefer a provider it never actually ran
   * against. */
  function unwind(e: Live): any[] {
    e.selected = {}
    const errors: any[] = []
    for (let i = e.scope.length - 1; 0 <= i; i--) {
      try { e.scope[i]() } catch (err) { errors.push(err) }
    }
    e.scope = []
    return errors
  }

  /** §8.3: "A failed release ends the instance in `failed`, exactly as a
   * failed callback does (§5.2) — a release that raised may have leaked,
   * and an instance that may be holding resources it cannot account for
   * must not be reactivated." */
  function releasecheck(e: Live, errors: any[]): void {
    if (0 === errors.length) return
    e.status = 'failed'
    const causes = errors.map((x) => (x && x.message) || String(x))
    fail('plugin_release_failed',
      'release failed for ' + e.ref + ': ' + causes.join('; '),
      { ref: e.ref, cause: causes })
  }

  function unmetof(e: Live): string[] {
    return requirements(e.options)
      .filter(gatesactivation)
      .filter((r) => 0 === providersof(r).length)
      .map((r) => r.name)
  }

  function chosen(e: Live, req: Required, remember: boolean): string | undefined {
    const cands = providersof(req)
    if (0 === cands.length) return undefined
    const held = e.selected[req.name]
    if (undefined !== held && cands.some((c) => c.ref === held)) return held
    if (remember) e.selected[req.name] = cands[0].ref
    return cands[0].ref
  }

  function boundproviders(e: Live): string[] {
    const out: string[] = []
    for (const r of requirements(e.options)) {
      if (!restartsonloss(r)) continue
      const ref = chosen(e, r, false)
      if (undefined !== ref && -1 === out.indexOf(ref)) out.push(ref)
    }
    return out
  }

  /** Live instances whose selected provider is `ref` and which would be
   * restarted by losing it. */
  function consumersof(ref: string): string[] {
    return Object.keys(inst).sort().filter((r) => {
      const c = inst[r]
      return r !== ref && 'live' === c.status &&
        -1 !== boundproviders(c).indexOf(ref)
    })
  }

  function holdersof(ref: string): string[] {
    return Object.keys(inst).sort().filter((r) => {
      const c = inst[r]
      if (r === ref || 'live' !== c.status) return false
      for (const req of requirements(c.options)) {
        if (!gatesactivation(req)) continue
        if (chosen(c, req, false) === ref) return true
      }
      return false
    })
  }

  function providersof(req: Required): Candidate[] {
    const cands: Candidate[] = []
    const asref = tryref(req.name)
    for (const ref of Object.keys(inst).sort()) {
      const t = inst[ref]
      if ('live' !== t.status) continue
      if (ref === asref) {
        cands.push({ ref, pos: t.pos, provides: { name: req.name } })
        continue
      }
      for (const p of t.provides) {
        if (p.name === req.name) cands.push({ ref, pos: t.pos, provides: p })
      }
    }
    return resolvecapability(req, cands)
  }

  function cascade(provider: Live, seen?: { [ref: string]: true }): void {
    const done = seen || {}
    if (done[provider.ref]) return
    done[provider.ref] = true

    for (const r of consumersof(provider.ref)) {
      const c = inst[r]
      if ('live' !== c.status) continue
      cascade(c, done)
      let bad = false
      try { run(c, 'deactivate', 'deactivate') } catch (err) { bad = true }
      const errors = unwind(c)
      if (bad || 0 < errors.length) {
        // §5.2: ANY failure during a transition lands the instance in
        // `failed`, and a cascaded consumer is not an exception.
        // Marking it `pending` instead handed it straight back to
        // `reconcile`, which would activate it again the moment the
        // provider returned — the one thing `failed` exists to stop.
        c.status = 'failed'
        continue
      }
      c.status = 'pending'
      c.unmet = unmetof(c)
    }
  }

  function held(e: Live): void {
    if ('hold' !== dependency) return
    if (coordinated) return
    const holders = holdersof(e.ref)
    if (0 === holders.length) return
    fail('plugin_dependency_held',
      'instance is required by live consumers: ' + e.ref,
      { ref: e.ref, holders })
  }

  function reconcile(): void {
    let moved = true
    let rounds = 0
    while (moved) {
      moved = false
      if (1000 < ++rounds) break

      // Losses first, so a cascade settles in one pass rather than
      // alternating with re-activations.
      for (const r of Object.keys(inst).sort()) {
        const e = inst[r]
        if ('live' !== e.status) continue
        const lost = requirements(e.options)
          .filter(gatesactivation)
          .filter((q) => 0 === providersof(q).length)
        if (0 === lost.length) continue
        if (lost.every((q) => !restartsonloss(q))) continue
        let bad = false
        try { run(e, 'deactivate', 'deactivate') } catch (err) { bad = true }
        const errors = unwind(e)
        if (bad || 0 < errors.length) {
          e.status = 'failed'
          moved = true
          continue
        }
        e.status = 'pending'
        e.unmet = unmetof(e)
        moved = true
      }

      for (const r of Object.keys(inst).sort()) {
        const e = inst[r]
        if ('pending' !== e.status) continue
        if (0 < unmetof(e).length) continue
        try {
          run(e, 'activate', 'activate')
          e.status = 'live'
          e.unmet = []
          moved = true
        }
        catch (err) {
          unwind(e)
          e.status = 'failed'
          moved = true
        }
      }
    }
  }

  // --- ordering ----------------------------------------------------

  function order(point?: string): string[] {
    const bindings: Binding[] = Object.keys(inst)
      .filter((r) => 'live' === inst[r].status)
      .sort((a, b) => inst[a].seq - inst[b].seq)
      .map((r) => ({ ref: r, pos: inst[r].pos, order: inst[r].order }))
    const spec = point ? points[point] : undefined
    return resolveorder(bindings, spec && spec.pin)
  }

  // --- points ------------------------------------------------------

  /** Live bindings on a point, in resolved order. Recomputed on any
   * change to the live set (§7) rather than cached at startup — the bug
   * a host discovers only when something deactivates in production. */
  function bound(point: string): Bound[] {
    const ranked = order(point)
    const out: Bound[] = []
    for (const ref of ranked) {
      const e = inst[ref]
      // The band is the INSTANCE's ordering block (§7), stamped by the
      // host. A plugin passing its own would be ranking itself above
      // the order its document declared.
      const band = (e.order && 'number' === typeof e.order.band) ? e.order.band : 0
      for (const b of e.bindings) {
        if (b.point === point) out.push({ ...b, band })
      }
    }
    return out
  }

  function emit(point: string, arg?: any): any {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if (spec.kind && 'hook' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a hook: ' + point, { point, kind: spec.kind })
    }
    return fanout(bound(point), (spec.mode || 'emit') as Mode, arg)
  }

  function call(point: string, ...args: any[]): any {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if ('chain' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a chain: ' + point, { point, kind: spec.kind })
    }
    const base = spec.base || ((x: any) => x)
    return compose(bound(point), base)(...args)
  }

  function provide(point: string, ...args: any[]): any {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if ('provider' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a provider: ' + point, { point, kind: spec.kind })
    }
    const pick = pickone(bound(point), spec)
    if (!pick.winner) return spec.default
    return pick.winner.fn(...args)
  }

  function shadowed(point: string): string[] {
    const spec = points[point]
    if (undefined === spec) return []
    return pickone(bound(point), spec).shadowed
  }

  function exports(spec: string): any {
    const all: Exported[] = []
    for (const ref of Object.keys(inst).sort()) {
      const e = inst[ref]
      if ('declared' === e.status || 'failed' === e.status) continue
      for (const k of Object.keys(e.exports)) all.push({ ref, key: k, value: e.exports[k] })
    }
    return resolveexport(spec, all)
  }

  function capability(name: string): string[] {
    const cands: Candidate[] = []
    for (const ref of Object.keys(inst).sort()) {
      const e = inst[ref]
      if ('live' !== e.status) continue
      for (const p of e.provides) {
        if (p.name === name) cands.push({ ref, pos: e.pos, provides: p })
      }
    }
    return resolvecapability({ name }, cands).map((c) => c.ref)
  }

  // --- documents ---------------------------------------------------

  function apply(doc: any, profile?: string): void {
    guard()
    const norm = normalizeconfig({
      doc, profile: profile || opts.profile,
      keys: opts.keys, reserved,
    })

    const want = norm.order
    const optionsof: { [ref: string]: any } = {}
    for (const ref of want) {
      optionsof[ref] = resolveoptions({
        ref, doc, profile: profile || opts.profile,
        shape: shapeof(ref),
        hostdefaults: opts.defaults && opts.defaults[parseref(ref).name],
      })
    }

    /** Should this ref be LIVE after the apply? False for a ref the
     * document declares lazy or inactive AND for one it does not name at
     * all — which is what makes "unload what is gone" and "unload what
     * was toggled off" one rule rather than two. */
    const wantlive = (ref: string): boolean => {
      const ent = norm.instance[ref]
      return undefined !== ent && ent.active && 'eager' === ent.start
    }

    const drop: string[] = []
    for (const ref of Object.keys(inst)) {
      if ('declared' === inst[ref].status) continue
      if (!wantlive(ref)) drop.push(ref)
    }
    // Reverse load order: highest `pos` first, ref-descending for a tie,
    // so a consumer declared after its provider goes down first.
    drop.sort((a, b) => (inst[b].pos - inst[a].pos) || (a < b ? 1 : a > b ? -1 : 0))
    for (const ref of drop) unload(ref)

    // --- phase 2: declare and patch EVERYTHING, in load order --------
    for (const ref of want) {
      const ent: Instance = norm.instance[ref]
      declare(ref, { order: ent.order, pos: ent.pos })
      // The bar is REASSERTED ON EVERY APPLY, in both directions — a
      // document that turns the instance back on clears it, which is
      // the whole point of a config switch.
      inst[ref].barred = !ent.active
      refill(inst[ref].options, optionsof[ref])
      inst[ref].order = ent.order
      inst[ref].pos = ent.pos
    }

    for (const ref of want) {
      if (wantlive(ref)) load(ref)
    }

    for (const ref of want) {
      if (wantlive(ref)) activate(ref)
    }
  }

  function shapeof(ref: string): any {
    const def = catalog.get(parseref(ref).name)
    return def && def.shape
  }

  function setoptions(ref: string, patch: any): void {
    guard()
    const e = need(ref)
    const previous = { ...e.options }
    refill(e.options, resolveoptions({
      ref: e.ref, shape: shapeof(e.ref), doc: {}, patch: merge(previous, patch),
    }))
    if ('live' === e.status) {
      if ('function' === typeof e.def.reconfigure) {
        intransition = true
        try { e.def.reconfigure(api(e), e.options, previous) }
        finally { intransition = false }
      }
      else {
        // Always correct and sometimes expensive; `reconfigure` exists
        // to make the common case cheap (§9.4).
        deactivate(e.ref)
        activate(e.ref)
      }
    }
  }

  function refill(target: any, source: any): void {
    for (const k of Object.keys(target)) delete target[k]
    for (const k of Object.keys(source || {})) target[k] = source[k]
  }

  function merge(a: any, b: any): any {
    const out: any = {}
    for (const k of Object.keys(a || {})) out[k] = a[k]
    for (const k of Object.keys(b || {})) out[k] = b[k]
    return out
  }

  function close(): void {
    coordinated = true
    try { for (const r of Object.keys(inst).sort().reverse()) unload(r) }
    finally { coordinated = false }
  }

  function positionof(ref: string, point: string): any {
    const e = inst[canonref(ref)]
    if (!e) fail('plugin_not_loaded', 'no such instance: ' + ref, { ref })
    const ranked = order(point)
    const index = ranked.indexOf(e.ref)
    return {
      index, count: ranked.length,
      outermost: 0 === index,
      innermost: index === ranked.length - 1,
    }
  }

  function hostdeclare(ref: string, spec?: DeclareSpec): Live {
    guard()
    return declare(ref, { ...(spec || {}), hostowned: true })
  }

  const self = {
    catalog, list, instance, order, observable, hostdeclare,
    trace: () => events.slice(),
    autotag, positionof,
    emit, call, provider: provide, shadowed, exports, capability,
    declare, load, activate, deactivate, unload, ready, apply, close,
    options: setoptions,
    define: (def: Definition) => catalog.add(def),
  }
  return self
}
