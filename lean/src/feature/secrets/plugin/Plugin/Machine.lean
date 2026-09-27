-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Machine.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Host

/-!
# The state machine (§5), and the instance api it hands to callbacks

Split from `Host` because everything here is mutually recursive:
`activate` calls `reconcile` calls `activate`, `unload` calls `cascade`,
and building an `InstApi` needs `nest`, which needs `makeHost`. Lean
wants one `partial def ... mutual` block for that, and a separate file
keeps the block readable.

See `Host`'s header for which functions are `partial` and why.
-/

namespace Plugin

/-- AUTO-TAGGING IS EXPLICIT (§4 rule 3): the LOWEST UNUSED POSITIVE
INTEGER tag. It needs a host because it must know what is already
declared, which is why it cannot live in the pure `ref` section. -/
partial def autoTag (h : HostState) (name : String) : PluginM String := do
  let rec go (n : Nat) : PluginM String := do
    let cand ← formatRef (.str name) (.str (toString n))
    match ← findInst h cand with
    | none => return cand
    | some _ => go (n + 1)
  go 1

def hostDeclare (h : HostState) (r0 : String) (spec : DeclareSpec) : PluginM InstState := do
  let r ←
    if spec.tag == "?" then autoTag h (refName (← canonRefS r0))
    else canonRefS r0
  if !spec.hostOwned then checkReservedH h r

  let defname := if spec.definition == "" then refName r else spec.definition
  let def_ ← match ← catalogGet h defname with
    | some d => pure d
    | none =>
      raise "plugin_unknown_definition" ("not in catalog: " ++ defname)
        (details1 "name" (.str defname))

  match ← findInst h r with
  -- §4 rule 1: a pair addresses at most one instance. Re-declaring the
  -- SAME definition is the idempotent case; a different one is a
  -- duplicate, not a silent overwrite (seneca) and not an impossibility
  -- (sdkgen).
  | some existing =>
    if existing.defName != def_.name then
      raise "plugin_ref_duplicate" ("instance already declared: " ++ r)
        (details1 "ref" (.str r))
    return existing
  | none =>
    let insts ← h.instances.get
    let sq ← h.seqn.get
    h.seqn.set (sq + 1.0)
    let e : InstState := {
      ref := r, defName := def_.name, seq := sq
      status := ← IO.mkRef "declared"
      pos := ← IO.mkRef (spec.pos.getD (Float.ofNat insts.length))
      -- NO OPTIONS ADOPTED HERE. `apply` resolves options and hands the
      -- map over; adopting the caller's map made target and source THE
      -- SAME MAP in the refill that follows, which cleared its own
      -- source and left a first-time instance with no options at all.
      -- Lean's values are immutable so that cannot happen here, and the
      -- rule is kept anyway so the ports read alike.
      options := ← IO.mkRef (match spec.options with
        | some o => if o.isMap then o else Value.vmap
        | none => Value.vmap)
      state := ← IO.mkRef Value.vmap
      order := ← IO.mkRef spec.order
      selected := ← IO.mkRef Value.vmap
      barred := ← IO.mkRef false
      unmet := ← IO.mkRef Value.vlist
      scope := ← IO.mkRef []
      bindings := ← IO.mkRef []
      inner := ← IO.mkRef none
      exports := ← IO.mkRef Value.vmap
      provides := ← IO.mkRef Value.vlist }
    h.instances.set (insts ++ [e])
    return e

mutual

/-- The record of closures a callback gets instead of the instance —
see `Defs`'s header for why Lean will not permit the instance itself. -/
partial def instApi (h : HostState) (e : InstState) : InstApi := {
  ref := e.ref
  name := refName e.ref
  tag := let cs := e.ref.toList
         if cs.contains '$' then String.mk ((cs.dropWhile (· != '$')).drop 1) else ""
  getOptions := e.options.get
  getState := e.state.get
  setState := fun v => e.state.set v
  bindHook := fun p f band => instBind h e p (some f) none band
  bindChain := fun p f band => instBind h e p none (some f) band
  exportValue := fun k v => do e.exports.set ((← e.exports.get).set k v)
  provides := fun p => do e.provides.set ((← e.provides.get).push p)
  acquire := instAcquire h e
  giveback := instGiveback h e
  release := instRelease h e
  position := fun p => positionOf h e.ref p
  nest := instNest h e
  activateSelf := do let _ ← hostActivate h e.ref }

partial def instBind (h : HostState) (e : InstState) (point : String)
    (hook : Option (Value → PluginM (Option Value)))
    (chain : Option ((Value → PluginM Value) → Value → PluginM Value))
    (band : Value) : PluginM Unit := do
  -- §12's `plugin_bind_scope`: "binding declared outside `define`". §8.1
  -- puts binding declaration in `define` and insertion at a SUCCESSFUL
  -- activate, and the guard was the half that never got written — so a
  -- binding added from `activate` went live without being part of the
  -- loaded definition, and a deactivate/activate cycle appended it
  -- again. The code was in the table before anything raised it.
  if (← h.phase.get) != "define" then
    raise "plugin_bind_scope" ("bind called outside define: " ++ point)
      ((Value.vmap.set "ref" (.str e.ref)).set "point" (.str point))
  if !h.points.has point then
    raise "plugin_point_unknown" ("no such point: " ++ point)
      (details1 "point" (.str point))
  e.bindings.set ((← e.bindings.get) ++
    [{ ref := e.ref, point := point,
       band := if band.isNum then band.asNum else 0.0, hook := hook, chain := chain }])

partial def instAcquire (h : HostState) (e : InstState) : PluginM Nat := do
  -- §8.1: resources are "acquired during `activate` — the scope's actual
  -- job".
  if (← h.phase.get) != "activate" then
    raise "plugin_release_scope" "acquire called outside activate"
  let scope ← e.scope.get
  e.scope.set (scope ++ [{ fn := none, done := ← IO.mkRef false, counts := true }])
  h.open_.set ((← h.open_.get) + 1.0)
  return scope.length

/-- Hand a resource back before teardown. Idempotent, and the scope keeps
the entry: unwinding it again must be a no-op, or releasing early would
make teardown wrong. -/
partial def instGiveback (h : HostState) (e : InstState) (i : Nat) : PluginM Unit := do
  let scope ← e.scope.get
  match scope[i]? with
  | none => return
  | some s =>
    if ← s.done.get then return
    s.done.set true
    if s.counts then h.open_.set ((← h.open_.get) - 1.0)

partial def instRelease (h : HostState) (e : InstState) (f : Option (PluginM Unit))
    : PluginM Unit := do
  -- §8.3: "`inst.release` outside `activate` is `plugin_release_scope`".
  -- Being in a transition is true in `define` too, and a scope entry
  -- registered there is never unwound — `unload` on a merely `loaded`
  -- instance does not unwind, because a loaded instance is not supposed
  -- to hold anything.
  if (← h.phase.get) != "activate" then
    raise "plugin_release_scope" "release called outside activate"
  -- SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
  -- resources CURRENTLY HELD, so an entry that is registered and then
  -- unwound must leave the count where it found it. Incrementing on
  -- registration and never decrementing made every `release` a permanent
  -- leak in the counter.
  e.scope.set ((← e.scope.get) ++ [{ fn := f, done := ← IO.mkRef false, counts := true }])
  h.open_.set ((← h.open_.get) + 1.0)

/-- AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
INNER ONE'S LIFETIME. Registering the teardown in the instance scope is
what makes that true rather than aspirational: the inner host closes when
the outer instance deactivates, in the same reverse unwind as every other
resource.

It does NOT count toward `open` — a teardown is not an acquisition
(`nest/open`).

The inner host SHARES the outer's catalog and points, which §10.1
already permits ("a catalog may be shared between hosts") and which is
what lets `nest` return a `HostApi` rather than a whole host — see
`Defs`'s header. -/
partial def instNest (h : HostState) (e : InstState) : PluginM HostApi := do
  if !(← h.intransition.get) then
    raise "plugin_release_scope" "nest called outside a lifecycle callback"
  let inner ← makeHost { catalog := some h.catalog, points := h.points, bases := h.bases }
  let api : HostApi := {
    ready := fun r => do let _ ← hostReady inner r
    list := hostList inner }
  e.scope.set ((← e.scope.get) ++
    [{ fn := some (hostClose inner), done := ← IO.mkRef false, counts := false }])
  e.inner.set (some api)
  return api

partial def runCb (h : HostState) (e : InstState) (at_ : String) : PluginM Unit := do
  h.log.set ((← h.log.get).push (.str (e.ref ++ ":" ++ at_)))
  let ev := (((Value.vmap.set "ref" (.str e.ref)).set "event" (.str at_)).set
    "seq" (.num e.seq)).set "status" (.str (← e.status.get))
  h.events.set ((← h.events.get).push ev)

  let def_ ← catalogGet h e.defName
  match def_.bind (callbackFor · at_) with
  | none => return
  | some f =>
    h.intransition.set true
    h.phase.set at_
    try
      f (instApi h e)
      h.intransition.set false
      h.phase.set ""
    catch err =>
      h.intransition.set false
      h.phase.set ""
      -- §12: `plugin_define_failed` and its three siblings are "a
      -- callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES
      -- A CODE KEEPS IT — the code is the error's identity, and a plugin
      -- that raised `store_unreachable` must not have it rewritten. Only
      -- a code-less error is wrapped, which is the ordinary case for a
      -- callback that let a library error escape.
      if err.code != "" && err.code != "plugin_bare" then throw err
      raise ("plugin_" ++ at_ ++ "_failed")
        (e.ref ++ " raised in " ++ at_ ++ ": " ++ err.text)
        ((Value.vmap.set "ref" (.str e.ref)).set "cause" (.str err.text))

partial def hostLoad (h : HostState) (r : String) (spec : DeclareSpec) : PluginM InstState := do
  guardHost h
  let e ← hostDeclare h r spec
  if (← e.status.get) != "declared" then return e   -- idempotent
  -- PRESENT AND NOT NULL, not merely present. Every driver builds its
  -- command spec with all four keys and a null for each absent one, so a
  -- presence test reads an omitted `options` as an authored empty and
  -- wipes the real ones.
  match spec.options with
  | some o => if o.isMap then e.options.set o
  | none => pure ()

  try runCb h e "define"
  catch err => e.status.set "failed"; throw err
  e.status.set "loaded"

  -- AT LOAD, and before anything runs: a cycle through restart-causing
  -- requirements does not settle, and the only safe time to report a
  -- non-terminating reconcile is before it starts (§11.3). `provides` is
  -- populated by `define`, which has just run, so this is the first
  -- moment the graph is complete.
  try checkCycle (← graphNodes h)
  catch err => e.status.set "failed"; throw err
  return e

/-- CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).

The cascade is part of the provider's own deactivation and runs BEFORE
the provider's `deactivate` callback and scope unwind, so a consumer's
teardown can still call the thing it depends on — flushing a buffer to
the store it is about to lose is exactly what a `deactivate` callback is
for. -/
partial def cascade (h : HostState) (prov : InstState) (seen : IO.Ref (List String))
    : PluginM Unit := do
  if (← seen.get).contains prov.ref then return
  seen.set ((← seen.get) ++ [prov.ref])
  for cref in ← consumersOf h prov.ref do
    match ← findInst h cref with
    | none => pure ()
    | some c =>
      if (← c.status.get) != "live" then continue
      cascade h c seen                        -- deepest-first
      let bad ← try runCb h c "deactivate"; pure false catch _ => pure true
      let errors ← unwind h c
      if bad || errors.len > 0 then
        -- §5.2: ANY failure during a transition lands the instance in
        -- `failed`, and a cascaded consumer is not an exception. Marking
        -- it `pending` instead handed it straight back to `reconcile`,
        -- which would activate it again the moment the provider returned
        -- — the one thing `failed` exists to stop.
        c.status.set "failed"
      else
        c.status.set "pending"
        c.unmet.set (← unmetOf h c)

partial def hostActivate (h : HostState) (r : String) : PluginM InstState := do
  guardHost h
  let e ← need h r
  let st ← e.status.get
  if st == "live" then return e                 -- no-op returning success
  if st == "failed" then
    raise "plugin_bad_state" ("instance has failed: " ++ e.ref) (details1 "ref" (.str e.ref))
  -- §9.6: `active: false` bars the instance from running, and the bar is
  -- on the INSTANCE rather than on the apply that set it. `ready`
  -- reaches this through `activate`, which is why one guard covers both
  -- verbs the design names.
  if ← e.barred.get then
    raise "plugin_inactive" ("instance is barred by active: false: " ++ e.ref)
      (details1 "ref" (.str e.ref))
  if st == "declared" then let _ ← hostLoad h e.ref {}

  -- A declared requirement that is not live means `pending`: activation
  -- is a STANDING REQUEST, not a one-shot event.
  let unmet ← unmetOf h e
  if unmet.len > 0 then
    e.unmet.set unmet
    e.status.set "pending"
    return e

  try runCb h e "activate"
  catch err =>
    -- Unwind whatever the partial activation captured, in reverse.
    let _ ← unwind h e
    e.status.set "failed"
    throw err

  -- §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every later
  -- question — the cascade, `hold`, `unmet` — reads it back rather than
  -- re-ranking, which is what "always-reluctant" means.
  for req in (requirements (← e.options.get)).items do
    let _ ← chosen h e req true
  e.status.set "live"
  reconcile h
  return e

partial def hostDeactivate (h : HostState) (r : String) : PluginM InstState := do
  guardHost h
  let e ← need h r
  let st ← e.status.get
  if st == "loaded" || st == "declared" then return e
  -- §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`. Falling
  -- through here ran the definition's `deactivate` on an instance that
  -- never completed activation and, if that callback happened to
  -- succeed, returned it to `loaded` — from where it could be activated
  -- again, which is precisely what `failed` exists to prevent.
  if st == "failed" then
    raise "plugin_bad_state" ("instance has failed: " ++ e.ref) (details1 "ref" (.str e.ref))
  if st == "pending" then
    -- DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It never
    -- reached activate, so it holds no scope and no live bindings;
    -- running the definition's deactivate there would be teardown
    -- without matching setup. It cannot fail.
    e.status.set "loaded"
    e.unmet.set Value.vlist
    return e

  held h e
  cascade h e (← IO.mkRef [])
  try runCb h e "deactivate"
  catch err =>
    let _ ← unwind h e
    e.status.set "failed"
    throw err
  releaseCheck e (← unwind h e)
  e.status.set "loaded"
  reconcile h
  return e

partial def hostUnload (h : HostState) (r : String) : PluginM Unit := do
  guardHost h
  let e ← need h r
  let st ← e.status.get
  if st == "live" || st == "pending" then
    if st == "live" then
      held h e
      cascade h e (← IO.mkRef [])
      try runCb h e "deactivate"
      catch err =>
        -- §5.2: ANY failure during a transition lands the instance in
        -- `failed`, with the scope STILL FULLY UNWOUND. An earlier draft
        -- let the raise propagate straight out of `unload`, which left
        -- the instance `live` and its scope untouched — reporting a
        -- failure while leaking exactly the resources the failure was
        -- about.
        let _ ← unwind h e
        e.status.set "failed"
        throw err
      releaseCheck e (← unwind h e)
    e.status.set "loaded"
  let drop : PluginM Unit := do
    h.instances.set ((← h.instances.get).filter (·.ref != e.ref))
  let st2 ← e.status.get
  if st2 == "loaded" || st2 == "failed" then
    try runCb h e "close"
    catch err => drop; throw err
  drop

partial def hostReady (h : HostState) (r0 : String) : PluginM InstState := do
  -- Runs the whole forward path in one call (§5.1). §15.2's verb list
  -- omits this; §5.1 defines it and §15.3's `declare` row requires the
  -- corpus to pin it, so the list was incomplete rather than excluding
  -- it (DOCS.md §4.2).
  guardHost h
  let r ← canonRefS r0
  if (← findInst h r).isNone then let _ ← hostDeclare h r {}
  match ← findInst h r with
  | some e => if (← e.status.get) == "declared" then let _ ← hostLoad h r {}
  | none => pure ()
  hostActivate h r

/-- EAGER reconciliation: run to a fixed point rather than scheduling.

Two directions, and both are the reason `pending` exists. Activation is a
STANDING REQUEST, not a one-shot event: a pending instance whose
requirement arrives activates without being asked again, and a LIVE
instance whose requirement is lost goes back to pending — recursively,
through its own consumers. -/
partial def reconcile (h : HostState) : PluginM Unit := do
  let rec loop (rounds : Nat) : PluginM Unit := do
    if rounds > 1000 then return
    let mut moved := false

    -- Losses first, so a cascade settles in one pass rather than
    -- alternating with re-activations.
    for r in ← sortedRefs h do
      match ← findInst h r with
      | none => pure ()
      | some e =>
        if (← e.status.get) != "live" then continue
        let mut lost : List Value := []
        for q in (requirements (← e.options.get)).items do
          if !gatesActivation q then continue
          if (← providersOf h q).len == 0 then lost := lost ++ [q]
        -- POLICY IS PER REQUIREMENT, not per instance (§11.3): only the
        -- definition that has the requirement knows what it can cope
        -- with, and one instance may hold both a `static` and a
        -- `dynamic` one. A `dynamic` requirement whose provider is gone
        -- leaves the consumer LIVE and notified.
        if lost.isEmpty || !lost.any restartsOnLoss then continue
        let bad ← try runCb h e "deactivate"; pure false catch _ => pure true
        let errors ← unwind h e
        if bad || errors.len > 0 then e.status.set "failed"
        else
          e.status.set "pending"
          e.unmet.set (← unmetOf h e)
        moved := true

    for r in ← sortedRefs h do
      match ← findInst h r with
      | none => pure ()
      | some e =>
        if (← e.status.get) != "pending" then continue
        if (← unmetOf h e).len > 0 then continue
        let ok ← try
            runCb h e "activate"
            for req in (requirements (← e.options.get)).items do
              let _ ← chosen h e req true
            e.status.set "live"
            e.unmet.set Value.vlist
            pure true
          catch _ => pure false
        if !ok then
          let _ ← unwind h e
          e.status.set "failed"
        moved := true

    if moved then loop (rounds + 1)
  loop 0

partial def hostClose (h : HostState) : PluginM Unit := do
  -- A bulk teardown removing the holders too, so `hold` is suspended for
  -- exactly those holders (§11.3) — while the consumers-first cascade
  -- still runs, which is the half that matters.
  h.coordinated.set true
  let all ← h.instances.get
  let mut keyed : List (Float × String) := []
  for e in all do keyed := keyed ++ [(← e.pos.get, e.ref)]
  -- Reverse load order: highest `pos` first, ref-descending for a tie,
  -- so a consumer declared after its provider goes down first.
  let refs := (Value.sortWith
    (fun a b => if a.1 != b.1 then a.1 > b.1 else Value.strLe b.2 a.2) keyed).map (·.2)
  -- A COORDINATED FLAG THAT SURVIVES A RAISE IS A DISABLED GUARD. The
  -- canonical wraps the teardown in `try`/`finally`; an unload that
  -- raises would skip the reset and leave the host permanently
  -- `coordinated`, so a caller that catches the error and carries on
  -- under `dependency: "hold"` gets ad-hoc deactivation with the holder
  -- check silently off.
  try
    for r in refs do
      if (← findInst h r).isSome then hostUnload h r
    h.coordinated.set false
  catch err =>
    h.coordinated.set false
    throw err

end

-- ---------------------------------------------------------------------
-- documents
-- ---------------------------------------------------------------------

def shapeOf (h : HostState) (r : String) : PluginM Value := do
  return match ← catalogGet h (refName r) with
    | some d => d.shape
    | none => .null

private def wantLive (ent : Value) : Bool :=
  ent.isMap && (ent.get "active").truthy && (ent.get "start").asStr == "eager"

def hostApply (h : HostState) (doc profile : Value) : PluginM Unit := do
  guardHost h
  let inp := (((Value.vmap.set "doc" doc).set
    "profile" (if profile.isNull then h.profile else profile)).set
    "keys" h.keys).set "reserved" h.reserved
  let norm ← normalizeConfig inp
  let want := ((norm.get "order").items).map (·.asStr)
  let instancespec := norm.get "instance"

  let mut optionsof := Value.vmap
  for r in want do
    let oin := (((Value.vmap.set "ref" (.str r)).set "doc" doc).set
      "profile" (if profile.isNull then h.profile else profile)).set
      "shape" (← shapeOf h r)
    let oin := if h.defaults.isMap then
        oin.set "hostdefaults" (h.defaults.get (refName r)) else oin
    optionsof := optionsof.set r (← resolveOptions oin)

  -- --- phase 1: deactivations and unloads, in REVERSE load order ---
  let mut dropping : List (Float × String) := []
  for e in ← h.instances.get do
    if (← e.status.get) == "declared" then continue
    if !wantLive (instancespec.get e.ref) then
      dropping := dropping ++ [(← e.pos.get, e.ref)]
  let dropRefs := (Value.sortWith
    (fun a b => if a.1 != b.1 then a.1 > b.1 else Value.strLe b.2 a.2) dropping).map (·.2)
  for r in dropRefs do hostUnload h r

  -- --- phase 2: declare and patch EVERYTHING, in load order --------
  for r in want do
    let ent := instancespec.get r
    let e ← hostDeclare h r { order := ent.get "order", pos := some (ent.get "pos").asNum }
    -- The bar is REASSERTED ON EVERY APPLY, in both directions — a
    -- document that turns the instance back on clears it, which is the
    -- whole point of a config switch.
    e.barred.set (!(ent.get "active").truthy)
    -- Where the other ports must refill the options map IN PLACE so
    -- callbacks that closed over it see the new values, this port's
    -- callbacks read the ref, so a write is the same observation.
    e.options.set (optionsof.get r)
    e.order.set (ent.get "order")
    e.pos.set (ent.get "pos").asNum

  -- --- phase 3: loads, then phase 4: activations, in load order ----
  for r in want do
    if wantLive (instancespec.get r) then let _ ← hostLoad h r {}
  for r in want do
    if wantLive (instancespec.get r) then let _ ← hostActivate h r

def hostSetOptions (h : HostState) (r : String) (patch : Value) : PluginM Unit := do
  guardHost h
  let e ← need h r
  let previous ← e.options.get
  let inp := (((Value.vmap.set "ref" (.str e.ref)).set "shape" (← shapeOf h e.ref)).set
    "doc" Value.vmap).set "patch" (mergeValue previous patch)
  e.options.set (← resolveOptions inp)

  if (← e.status.get) != "live" then return
  match (← catalogGet h e.defName).bind (·.reconfigure) with
  | some f =>
    h.intransition.set true
    h.phase.set "reconfigure"
    try
      f (instApi h e) (← e.options.get) previous
      h.intransition.set false
      h.phase.set ""
    catch err =>
      h.intransition.set false
      h.phase.set ""
      throw err
  | none =>
    -- Always correct and sometimes expensive; `reconfigure` exists to
    -- make the common case cheap (§9.4).
    let _ ← hostDeactivate h e.ref
    let _ ← hostActivate h e.ref

end Plugin
