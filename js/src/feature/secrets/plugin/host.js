// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (javascript/src/host.js)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The host: the lifecycle state machine (§5), extension points (§6), and
 * resource capture (§8).
 *
 * TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * Transitions are SEQUENTIAL (§5.2). One at a time, in call order, never
 * interleaved; a transition triggered from inside a lifecycle callback
 * is `plugin_reentrant`. A hard rule, because it is the only way the
 * semantics can be identical in Go, in Ruby and in single-threaded
 * JavaScript.
 *
 * Reconciliation is EAGER (§18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by
 * suspending on a promise. Every port must be able to do the same, and
 * fourteen of them will not have JavaScript's event loop. */

'use strict'

const { fail } = require('./types')
const { canonref, tryref, parseref, formatref } = require('./ref')
const { makecatalog } = require('./catalog')
const { resolveorder } = require('./order')
const { emit: fanout, compose, provider: pickone } = require('./point')
const { resolveexport } = require('./export')
const { resolvecapability } = require('./capability')
const { normalizeconfig, resolveoptions } = require('./config')
const {
  checkcycle, gatesactivation, requirements, restartsonloss,
} = require('./depend')

function makehost(options) {
  const dependency = (options && options.dependency) || 'restart'
  /** Set for the duration of a bulk teardown, so `held` knows this is a
   * coordinated operation rather than an ad-hoc deactivation. */
  let coordinated = false

  const opts = options || {}
  const catalog = opts.catalog || makecatalog()
  const reserved = opts.reserved || []
  const points = opts.points || {}

  const inst = {}
  const log = []
  /** §14: the lifecycle event record. `seq` distinguishes ONE
   * INCARNATION of stripe$test from the next, which is the whole reason
   * it is not `pos` (§4 rule 4). */
  const events = []
  let seqn = 0
  let open = 0
  let intransition = false
  /** WHICH callback is running, not merely that one is. §8.1 puts
   * resource capture in `activate` and §8.3 says `inst.release` outside
   * `activate` is `plugin_release_scope` — and `intransition` alone
   * cannot tell `activate` from `define`, so it admitted an acquire in
   * `define` whose scope `unload` would never unwind. */
  let phase = null

  // --- observation -------------------------------------------------

  /** Introspection NEVER advances the state (§5.2). A status page must
   * not be a way to accidentally import twenty packages. */
  const list = () => {
    const out = {}
    for (const r of Object.keys(inst).sort()) out[r] = inst[r].status
    return out
  }

  const instance = (ref) => inst[canonref(ref)]

  const observable = (result) => ({
    status: list(),
    open,
    log: log.slice(),
    result: undefined === result ? null : result,
  })

  // --- the state machine -------------------------------------------

  function guard() {
    if (intransition) {
      fail('plugin_reentrant', 'transition attempted from inside a lifecycle callback')
    }
  }

  function need(ref) {
    const r = canonref(ref)
    const e = inst[r]
    if (!e) fail('plugin_not_loaded', 'no such instance: ' + r, { ref: r })
    return e
  }

  function checkreserved(ref) {
    if (0 === reserved.length) return
    if (-1 !== reserved.indexOf(parseref(ref).name)) {
      fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
    }
  }

  function run(e, cb, at) {
    const fn = e.def[cb]
    log.push(e.ref + ':' + at)
    events.push({ ref: e.ref, event: at, seq: e.seq, status: e.status })
    if ('function' !== typeof fn) return
    intransition = true
    phase = at
    try {
      fn(api(e))
    }
    catch (err) {
      // §12: `plugin_define_failed` and its three siblings are "a
      // callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES
      // A CODE KEEPS IT — the code is the error's identity, and a plugin
      // that raised `store_unreachable` must not have it rewritten.
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

  /** What a definition's callbacks see. Deliberately not the internal
   * record: a plugin that could reach `status` could also write it. */
  function api(e) {
    return {
      ref: e.ref,
      name: parseref(e.ref).name,
      tag: parseref(e.ref).tag,
      options: e.options,
      state: e.state,
      /** Foreign resources the host did not hand out are registered
       * explicitly (§8.3); host calls are recorded automatically.
       *
       * SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
       * resources CURRENTLY HELD, so an entry that is registered and
       * then unwound must leave the count where it found it. */
      release: (fn) => {
        // §8.3: "`inst.release` outside `activate` is
        // `plugin_release_scope`". `intransition` is true in `define`
        // too, and a scope entry registered there is never unwound.
        if ('activate' !== phase) {
          fail('plugin_release_scope', 'release called outside activate')
        }
        let done = false
        e.scope.push(() => { if (!done) { done = true; open -= 1; fn() } })
        open += 1
      },
      /** The synthetic counter the driver owns, so "what is open" is
       * data rather than an assertion each port words differently.
       *
       * Returns its own release, so a plugin can hand one back early.
       * The scope still holds the entry and unwinding it twice is a
       * no-op — releasing early must not make teardown wrong. */
      acquire: () => {
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

      /** Bind into a host point. Declared in `define`; the host inserts
       * it only after `activate` returns successfully (§8.1), which is
       * why a failing activate leaves no live binding behind. */
      bind: (point, fn, band) => {
        // §12's `plugin_bind_scope`: "binding declared outside
        // `define`". §8.1 puts binding DECLARATION in `define` and
        // INSERTION at a successful activate, and the guard was the half
        // nobody wrote — so a binding added from `activate` went live
        // without being part of the loaded definition, and a
        // deactivate/activate cycle appended it again.
        if ('define' !== phase) {
          fail('plugin_bind_scope', 'bind called outside define: ' + point,
            { ref: e.ref, point })
        }
        if (undefined === points[point]) {
          fail('plugin_point_unknown', 'no such point: ' + point, { point })
        }
        e.bindings.push({ ref: e.ref, point, fn, band: band || 0 })
      },

      /** Published for other plugins and for the application (§11). */
      export: (key, value) => { e.exports[key] = value },

      /** What this instance can do for others (§11.1). */
      provides: (p) => { e.provides.push(p) },

      /** Where this binding landed (§6.6) — the plugin-side counterpart
       * to a host pin. THE HOST DOES NOT POLICE THIS; it just makes the
       * fact available. Verification tells a plugin it was misplaced; a
       * pin (§7) stops the misplacement from being expressible at all.
       * The two are not substitutes. */
      position: (point) => positionof(e.ref, point),

      /** AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS
       * THE INNER ONE'S LIFETIME. Registering the teardown in the
       * instance scope is what makes that true rather than aspirational:
       * the inner host closes when the outer instance deactivates, in
       * the same reverse unwind as every other resource. */
      nest: (nestopts) => {
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

  /** AUTO-TAGGING IS EXPLICIT (§4 rule 3). `declare('stripe', {tag:
   * '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns
   * the assigned pair. Without `'?'`, a collision is an error.
   *
   * It needs a host because it must know what is already declared, which
   * is why it cannot live in the pure `ref` section. */
  function autotag(name) {
    for (let n = 1; ; n++) {
      const cand = formatref(name, String(n))
      if (undefined === inst[cand]) return cand
    }
  }

  function declare(ref, spec) {
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
      // the SAME definition is the idempotent case; a different one is a
      // duplicate, not a silent overwrite (seneca) and not an
      // impossibility (sdkgen).
      if (existing.def.name !== def.name) {
        fail('plugin_ref_duplicate', 'instance already declared: ' + r, { ref: r })
      }
      return existing
    }

    const e = {
      ref: r, def, status: 'declared',
      pos: undefined === s.pos ? Object.keys(inst).length : s.pos,
      seq: seqn++,
      options: s.options || {},
      state: {}, order: s.order, unmet: [], scope: [],
      bindings: [], exports: {}, provides: [],
      // §11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider
      // ref this instance's activation actually chose, per requirement
      // name. Re-ranking on every question silently re-points a live
      // consumer at any better newcomer, and then losing the provider it
      // was really using does not restart it.
      selected: {},
    }
    inst[r] = e
    return e
  }

  function load(ref, spec) {
    guard()
    const e = declare(ref, spec)
    if ('declared' !== e.status) return e   // idempotent in the trivial direction
    if (spec && spec.options) e.options = spec.options
    try {
      run(e, 'define', 'define')
    }
    catch (err) {
      e.status = 'failed'
      throw err
    }
    e.status = 'loaded'

    // AT LOAD, and before anything runs: a cycle through restart-causing
    // requirements does not settle, and the only safe time to report a
    // non-terminating reconcile is before it starts (§11.3). `provides`
    // is populated by `define`, which has just run, so this is the first
    // moment the graph is complete.
    try { checkcycle(graphnodes()) }
    catch (err) {
      e.status = 'failed'
      throw err
    }
    return e
  }

  /** The requirement graph as plain data, for the pure detector. */
  function graphnodes() {
    return Object.keys(inst).sort().map((r) => ({
      ref: r,
      provides: inst[r].provides.map((p) => p.name),
      requires: requirements(inst[r].options),
    }))
  }

  function activate(ref) {
    guard()
    const e = need(ref)
    if ('live' === e.status) return e        // no-op returning success
    if ('failed' === e.status) {
      fail('plugin_bad_state', 'instance has failed: ' + e.ref, { ref: e.ref })
    }
    // §9.6: `active: false` bars the instance from running, and the bar
    // is on the INSTANCE rather than on the apply that set it. `ready`
    // reaches this through `activate`, so one guard covers both verbs
    // the design names.
    if (e.barred) {
      fail('plugin_inactive', 'instance is barred by active: false: ' + e.ref,
        { ref: e.ref })
    }
    if ('declared' === e.status) load(e.ref)

    // A declared requirement that is not live means `pending`:
    // activation is a STANDING REQUEST, not a one-shot event.
    if (0 < unmetof(e).length) {
      e.unmet = unmetof(e)
      e.status = 'pending'
      return e
    }

    try {
      run(e, 'activate', 'activate')
    }
    catch (err) {
      // Unwind whatever the partial activation captured, in reverse.
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

  function deactivate(ref) {
    guard()
    const e = need(ref)
    if ('loaded' === e.status || 'declared' === e.status) return e

    // §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
    if ('failed' === e.status) {
      fail('plugin_bad_state', 'instance has failed: ' + e.ref, { ref: e.ref })
    }

    if ('pending' === e.status) {
      // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
      // never reached activate, so it holds no scope and no live
      // bindings; running the definition's deactivate there would be
      // teardown without matching setup, which plugins are not written
      // to survive and which could fail an instance that had done
      // nothing wrong. It cannot fail.
      e.status = 'loaded'
      e.unmet = []
      return e
    }

    held(e)
    cascade(e)

    try {
      run(e, 'deactivate', 'deactivate')
    }
    catch (err) {
      unwind(e)
      e.status = 'failed'
      throw err
    }
    releasecheck(e, unwind(e))
    e.status = 'loaded'
    reconcile()
    return e
  }

  function unload(ref) {
    guard()
    const e = need(ref)
    if ('live' === e.status || 'pending' === e.status) {
      if ('live' === e.status) {
        held(e)
        cascade(e)
        try {
          run(e, 'deactivate', 'deactivate')
        }
        catch (err) {
          // §5.2: ANY failure during a transition lands the instance in
          // `failed`, with the scope STILL FULLY UNWOUND — and the
          // instance STAYS REGISTERED, because `failed` is a state an
          // operator has to be able to see.
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

  function ready(ref) {
    // Runs the whole forward path in one call (§5.1).
    guard()
    const r = canonref(ref)
    if (!inst[r]) declare(r)
    if ('declared' === inst[r].status) load(r)
    return activate(r)
  }

  /** Bindings go live only when activation succeeds (§8.1), so the
   * teardown is the exact inverse: reverse order, always. */
  /** A selection belongs to ONE activation (§11.4). Leaving `live` by
   * any door drops it, so the next activation ranks afresh — keeping it
   * would make a consumer prefer a provider it never ran against. */
  function unwind(e) {
    e.selected = {}
    const errors = []
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
  function releasecheck(e, errors) {
    if (0 === errors.length) return
    e.status = 'failed'
    const causes = errors.map((x) => (x && x.message) || String(x))
    fail('plugin_release_failed',
      'release failed for ' + e.ref + ': ' + causes.join('; '),
      { ref: e.ref, cause: causes })
  }

  /** A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1). A bare
   * string is shorthand for `{name}`. A ref satisfies too, because a
   * host that genuinely needs a specific instance should not have to
   * invent a capability for it. */
  function unmetof(e) {
    return requirements(e.options)
      .filter(gatesactivation)
      .filter((r) => 0 === providersof(r).length)
      .map((r) => r.name)
  }

  /** The instance currently SELECTED for each of this one's
   * restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
   * capability (§11.1): the selected one going away restarts a `static`
   * consumer even though a survivor is available. */
  /** §11.4's always-reluctant selection, and the ONE place a provider is
   * picked for a live instance. If this instance already selected a
   * provider for `req` and that provider is STILL a candidate, it keeps
   * it — a better-ranked newcomer does not take it. `remember` is false
   * for the questions asked ABOUT an instance rather than BY it:
   * introspection must not create a binding. */
  function chosen(e, req, remember) {
    const cands = providersof(req)
    if (0 === cands.length) return undefined
    const held = e.selected[req.name]
    if (undefined !== held && cands.some((c) => c.ref === held)) return held
    if (remember) e.selected[req.name] = cands[0].ref
    return cands[0].ref
  }

  function boundproviders(e) {
    const out = []
    for (const r of requirements(e.options)) {
      if (!restartsonloss(r)) continue
      const ref = chosen(e, r, false)
      if (undefined !== ref && -1 === out.indexOf(ref)) out.push(ref)
    }
    return out
  }

  /** Live instances whose selected provider is `ref` and which would be
   * restarted by losing it. */
  function consumersof(ref) {
    return Object.keys(inst).sort().filter((r) => {
      const c = inst[r]
      return r !== ref && 'live' === c.status &&
        -1 !== boundproviders(c).indexOf(ref)
    })
  }

  /** §11.3's `hold` asks a DIFFERENT question from the cascade, and
   * reading it off `consumersof` answered the cascade's.
   *
   * The cascade wants the edges that RESTART — mandatory-static and
   * optional-static — because a restart is what it performs. `hold`
   * says "deactivating a REQUIRED instance is
   * `plugin_dependency_held`", and required is cardinality:
   * `gatesactivation`, not `restartsonloss`. The two sets differ in
   * both directions and each difference was a real bug.
   *
   * A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy
   * let a provider go that a live consumer could not do without —
   * `dynamic` promises survival of a SWAP, and under `hold` there is no
   * swap, so the consumer falls back to `pending`.
   *
   * An OPTIONAL-STATIC consumer was included, so `hold` refused a
   * deactivation on behalf of an instance that had said in writing it
   * does not need the thing. */
  function holdersof(ref) {
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

  function providersof(req) {
    const cands = []
    // ASK WHETHER THE NAME IS A REF, do not assume it. A requirement name
    // is a CAPABILITY name first (§11.1) and capability names are
    // free-form, so `2fa` is a legal one that no ref could be called —
    // and `canonref` RAISES on those, which made a legal document kill
    // the host right here. `tryref` answers `undefined` instead, and
    // still canonicalizes when it is a ref (§4 rule 5).
    const asref = tryref(req.name)
    for (const ref of Object.keys(inst).sort()) {
      const t = inst[ref]
      if ('live' !== t.status) continue
      // A ref satisfies directly.
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

  /** CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
   *
   * The cascade is part of the provider's own deactivation and runs
   * BEFORE the provider's `deactivate` callback and scope unwind, so a
   * consumer's teardown can still call the thing it depends on —
   * flushing a buffer to the store it is about to lose is exactly what a
   * `deactivate` callback is for, and a cascade that fired after the
   * provider was already gone would make that impossible. */
  function cascade(provider, seen) {
    const done = seen || {}
    if (done[provider.ref]) return
    done[provider.ref] = true

    for (const r of consumersof(provider.ref)) {
      const c = inst[r]
      if ('live' !== c.status) continue
      cascade(c, done)                     // deepest-first
      let bad = false
      try { run(c, 'deactivate', 'deactivate') } catch (err) { bad = true }
      const errors = unwind(c)
      if (bad || 0 < errors.length) {
        // §5.2: ANY failure during a transition lands the instance in
        // `failed`. Marking it `pending` handed it back to `reconcile`,
        // which would activate it again the moment the provider
        // returned.
        c.status = 'failed'
        continue
      }
      c.status = 'pending'
      c.unmet = unmetof(c)
    }
  }

  /** The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
   * COORDINATED TEARDOWN. In a bulk operation that is removing the
   * holders too — `close()`, or an `apply` plan whose own steps
   * deactivate them — it is suspended for exactly those holders, and the
   * teardown still runs consumers before providers. */
  function held(e) {
    if ('hold' !== dependency) return
    if (coordinated) return
    const holders = holdersof(e.ref)
    if (0 === holders.length) return
    fail('plugin_dependency_held',
      'instance is required by live consumers: ' + e.ref,
      { ref: e.ref, holders })
  }

  /** EAGER reconciliation: run to a fixed point rather than scheduling.
   *
   * Two directions, and both are the reason `pending` exists. Activation
   * is a STANDING REQUEST, not a one-shot event. */
  function reconcile() {
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
        // POLICY IS PER REQUIREMENT, not per instance (§11.3). A
        // `dynamic` requirement whose provider is gone leaves the
        // consumer LIVE and notified.
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

  function order(point) {
    // Sorted by declaration SEQUENCE, which is what makes the §7 sort's
    // fall-through deterministic in a language whose maps have no
    // insertion order. §7 breaks ties by `pos`; two instances CAN share
    // one — `declare` defaults `pos` to the registry size, so an unload
    // followed by a fresh declare reuses a surviving instance's — and
    // past that this was falling through to `Object.keys`. `seq` is that
    // order, made explicit.
    const bindings = Object.keys(inst)
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
  function bound(point) {
    const ranked = order(point)
    const out = []
    for (const ref of ranked) {
      const e = inst[ref]
      // The band is the INSTANCE's ordering block (§7), stamped by the
      // host. A plugin passing its own would be ranking itself above the
      // order its document declared.
      const band = (e.order && 'number' === typeof e.order.band) ? e.order.band : 0
      for (const b of e.bindings) {
        if (b.point === point) out.push({ ...b, band })
      }
    }
    return out
  }

  function emit(point, arg) {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if (spec.kind && 'hook' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a hook: ' + point, { point, kind: spec.kind })
    }
    return fanout(bound(point), spec.mode || 'emit', arg)
  }

  function call(point, ...args) {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if ('chain' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a chain: ' + point, { point, kind: spec.kind })
    }
    const base = spec.base || ((x) => x)
    return compose(bound(point), base)(...args)
  }

  function provide(point, ...args) {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if ('provider' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a provider: ' + point, { point, kind: spec.kind })
    }
    const pick = pickone(bound(point), spec)
    if (!pick.winner) return spec.default
    return pick.winner.fn(...args)
  }

  /** The losers are VISIBLE rather than silently ignored (§6.3). */
  function shadowed(point) {
    const spec = points[point]
    if (undefined === spec) return []
    return pickone(bound(point), spec).shadowed
  }

  function exports(spec) {
    const all = []
    for (const ref of Object.keys(inst).sort()) {
      const e = inst[ref]
      // Exports of a `loaded` (not live) instance are VISIBLE (§11).
      if ('declared' === e.status || 'failed' === e.status) continue
      for (const k of Object.keys(e.exports)) all.push({ ref, key: k, value: e.exports[k] })
    }
    return resolveexport(spec, all)
  }

  /** The live providers of a capability, best-first (§11.1). */
  function capability(name) {
    const cands = []
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

  /** §9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
   * changed, and move activation state to match", with the stated
   * ordering — "deactivations and unloads first (reverse load order),
   * then loads, then activations in load order".
   *
   * FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
   * document once, which never looked at instances the new document had
   * DROPPED — so an integration removed from a config reload stayed live
   * with its bindings and resources. */
  function apply(doc, profile) {
    guard()
    const norm = normalizeconfig({
      doc, profile: profile || opts.profile,
      keys: opts.keys, reserved,
    })

    const want = norm.order
    const optionsof = {}
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
    const wantlive = (ref) => {
      const ent = norm.instance[ref]
      return undefined !== ent && ent.active && 'eager' === ent.start
    }

    // --- phase 1: deactivations and unloads, in REVERSE load order ---
    const drop = []
    for (const ref of Object.keys(inst)) {
      if ('declared' === inst[ref].status) continue
      if (!wantlive(ref)) drop.push(ref)
    }
    drop.sort((a, b) => (inst[b].pos - inst[a].pos) || (a < b ? 1 : a > b ? -1 : 0))
    for (const ref of drop) unload(ref)

    // --- phase 2: declare and patch EVERYTHING, in load order --------
    for (const ref of want) {
      const ent = norm.instance[ref]
      // NO OPTIONS HERE, and the omission is the fix rather than an
      // oversight. `declare` ADOPTS the options map it is handed as the
      // instance's own, so passing the resolved map made target and
      // source THE SAME MAP in the refill three lines below — which
      // cleared its own source and left a first-time instance with no
      // options at all. `declare` makes its own empty map and the refill
      // fills it, so both paths are now one path.
      declare(ref, { order: ent.order, pos: ent.pos })
      // The bar is REASSERTED ON EVERY APPLY, in both directions — a
      // document that turns the instance back on clears it, which is
      // the whole point of a config switch.
      inst[ref].barred = !ent.active
      // REFILL rather than REBIND. A definition's callbacks close over
      // the options map they were handed at `define`; replacing the
      // reference here would leave every binding reading the values the
      // first apply gave it.
      refill(inst[ref].options, optionsof[ref])
      inst[ref].order = ent.order
      inst[ref].pos = ent.pos
    }

    // --- phase 3: loads, in load order -------------------------------
    // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances
    // is twenty map entries and no executed code" (§9.6).
    for (const ref of want) {
      if (wantlive(ref)) load(ref)
    }

    // --- phase 4: activations, in load order -------------------------
    for (const ref of want) {
      if (wantlive(ref)) activate(ref)
    }
  }

  function shapeof(ref) {
    const def = catalog.get(parseref(ref).name)
    return def && def.shape
  }

  function setoptions(ref, patch) {
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

  /** Empty the target and refill it, so callers holding the reference
   * see the new values. */
  function refill(target, source) {
    for (const k of Object.keys(target)) delete target[k]
    for (const k of Object.keys(source || {})) target[k] = source[k]
  }

  function merge(a, b) {
    const out = {}
    for (const k of Object.keys(a || {})) out[k] = a[k]
    for (const k of Object.keys(b || {})) out[k] = b[k]
    return out
  }

  function close() {
    // A bulk teardown removing the holders too, so `hold` is suspended
    // for exactly those holders (§11.3) - while the consumers-first
    // cascade still runs, which is the half that matters.
    coordinated = true
    try { for (const r of Object.keys(inst).sort().reverse()) unload(r) }
    finally { coordinated = false }
  }

  /** The same record §6.6 gives a plugin about itself, reachable from
   * outside for the corpus. */
  function positionof(ref, point) {
    const e = inst[canonref(ref)]
    if (!e) fail('plugin_not_loaded', 'no such instance: ' + ref, { ref })
    const ranked = order(point)
    const index = ranked.indexOf(e.ref)
    return {
      index, count: ranked.length,
      // §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST,
      // so these are not index 0 and index count-1 the other way round.
      outermost: 0 === index,
      innermost: index === ranked.length - 1,
    }
  }

  /** §9.1: a host that reserves a name MUST still be able to declare the
   * instance it reserved — "The host declares those instances itself,
   * after the user merge, and always wins."
   *
   * THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit:
   * no language here can tell the embedding host from a plugin holding
   * the same host object. What reservation protects is CONFIGURATION —
   * documents, overlays, `VOXGIG_PLUGIN_*`, construction options and
   * ordinary `declare`/`load`/`options` — and all of that still checks. */
  function hostdeclare(ref, spec) {
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
    define: (def) => catalog.add(def),
  }
  return self
}

module.exports = { makehost }
