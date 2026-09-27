-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Host.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Capability
import Plugin.Config
import Plugin.Defs
import Plugin.Depend
import Plugin.Export
import Plugin.Order

/-!
# The host: lifecycle (§5), extension points (§6), resource capture (§8)

TWO RULES SHAPE EVERY FUNCTION HERE.

Transitions are SEQUENTIAL (§5.2). One at a time, in call order, never
interleaved; a transition triggered from inside a lifecycle callback is
`plugin_reentrant`. A hard rule, because it is the only way the
semantics can be identical in Go, in Ruby and in single-threaded
JavaScript — and in Lean, which has no event loop to hide behind.

Reconciliation is EAGER (§18's portability budget). A transition settles
by running the state machine to a fixed point, not by suspending.

WHAT IS `partial` HERE, AND WHY. Lean asks every recursive function for
a termination argument. Most of this file is structural and needs none.
Three do not terminate structurally, and each is `partial` for a reason
worth reading:

- `reconcile` — settles by reaching a fixed point, bounded by an
  explicit round cap. Its termination is a SEMANTIC property of the
  state machine, not a structural one.
- `cascade` — recurses over the consumer graph, guarded by a `seen` set.
  Terminating because the graph is finite and the guard is honoured;
  proving that would mean carrying the invariant in the type.
- `unloadAt`/`activateAt` — mutually recursive with `reconcile`.

Marking them `partial` says exactly that: the proof is not free, and the
corpus is what checks them instead.
-/

namespace Plugin

-- ---------------------------------------------------------------------
-- construction and registry helpers
-- ---------------------------------------------------------------------

def makeCatalog : PluginM (IO.Ref (List Definition)) := IO.mkRef []

def makeHost (o : HostOptions) : PluginM HostState := do
  let cat ← match o.catalog with
    | some c => pure c
    | none => makeCatalog
  return {
    catalog := cat
    reserved := o.reserved, keys := o.keys, defaults := o.defaults
    profile := o.profile
    points := if o.points.isMap then o.points else Value.vmap
    bases := o.bases
    dependency := if o.dependency == "" then "restart" else o.dependency
    coordinated := ← IO.mkRef false
    instances := ← IO.mkRef []
    log := ← IO.mkRef Value.vlist
    events := ← IO.mkRef Value.vlist
    seqn := ← IO.mkRef 0.0
    open_ := ← IO.mkRef 0.0
    intransition := ← IO.mkRef false
    phase := ← IO.mkRef "" }

def hostDefine (h : HostState) (d : Definition) : PluginM Unit := do
  if !checkname (.str d.name) then
    raise "plugin_definition_name" ("invalid definition name: " ++ d.name)
  -- Validate the shape HERE. Deferring it to resolution time means a
  -- malformed shape surfaces at a different moment in every host that
  -- loads it, which is the divergence the stated domain exists to
  -- prevent.
  if !d.shape.isNull then checkShape d.shape
  let defs ← h.catalog.get
  if defs.any (·.name == d.name) then
    h.catalog.set (defs.map (fun x => if x.name == d.name then d else x))
  else h.catalog.set (defs ++ [d])

def catalogGet (h : HostState) (name : String) : PluginM (Option Definition) := do
  return (← h.catalog.get).find? (·.name == name)

def findInst (h : HostState) (r : String) : PluginM (Option InstState) := do
  return (← h.instances.get).find? (·.ref == r)

/-- Every instance ref, SORTED — the deterministic walk §4 rule 4
requires in a language whose containers have no inherent order. -/
def sortedRefs (h : HostState) : PluginM (List String) := do
  return Value.sortWith Value.strLe ((← h.instances.get).map (·.ref))

def callbackFor (d : Definition) (at_ : String) : Option (InstApi → PluginM Unit) :=
  if at_ == "define" then d.define
  else if at_ == "activate" then d.activate
  else if at_ == "deactivate" then d.deactivate
  else if at_ == "close" then d.close
  else none

-- ---------------------------------------------------------------------
-- observation
-- ---------------------------------------------------------------------

def hostList (h : HostState) : PluginM Value := do
  let mut out := Value.vmap
  for r in ← sortedRefs h do
    match ← findInst h r with
    | some e => out := out.set r (.str (← e.status.get))
    | none => pure ()
  return out

/-- The VALIDATING canonicalizer, not the forgiving one: a lookup with a
malformed ref is `plugin_bad_name`, not a miss
(`declare/lookup#malformed`). Rust and swift both wrote this with
`canon` and failed that entry. -/
def hostInstance (h : HostState) (r : String) : PluginM (Option InstState) := do
  findInst h (← canonRefS r)

def observable (h : HostState) (result : Option Value) : PluginM Value := do
  return (((Value.vmap.set "status" (← hostList h)).set "open" (.num (← h.open_.get))).set
    "log" (← h.log.get)).set "result" (result.getD .null)

def hostTrace (h : HostState) : PluginM Value := h.events.get

-- ---------------------------------------------------------------------
-- guards
-- ---------------------------------------------------------------------

def guardHost (h : HostState) : PluginM Unit := do
  if ← h.intransition.get then
    raise "plugin_reentrant" "transition attempted from inside a lifecycle callback"

def need (h : HostState) (r0 : String) : PluginM InstState := do
  let r ← canonRefS r0
  match ← findInst h r with
  | some e => return e
  | none => raise "plugin_not_loaded" ("no such instance: " ++ r) (details1 "ref" (.str r))

def checkReservedH (h : HostState) (r : String) : PluginM Unit := do
  if h.reserved.isList && h.reserved.len > 0 then
    if (h.reserved.items).any (fun x => x.isStr && x.asStr == refName r) then
      raise "plugin_ref_reserved" ("ref is reserved by the host: " ++ r)
        (details1 "ref" (.str r))

-- ---------------------------------------------------------------------
-- scope
-- ---------------------------------------------------------------------

/-- A selection belongs to ONE activation (§11.4). Leaving `live` by any
door drops it, so the next activation ranks afresh — keeping it would
make a consumer prefer a provider it never actually ran against.

Answers the errors the scope raised. §8.3: "A failing release does not
stop the rest. Every entry runs, in reverse order, whatever any of them
does; the errors are collected and raised as one
`plugin_release_failed`." -/
def unwind (h : HostState) (e : InstState) : PluginM Value := do
  e.selected.set Value.vmap
  let entries ← e.scope.get
  let mut errors : List Value := []
  for s in entries.reverse do
    if ← s.done.get then continue
    s.done.set true
    if s.counts then h.open_.set ((← h.open_.get) - 1.0)
    match s.fn with
    | none => pure ()
    | some f =>
      try f
      catch err => errors := errors ++ [.str err.message]
  e.scope.set []
  return .list errors

/-- §8.3: "A failed release ends the instance in `failed`, exactly as a
failed callback does (§5.2) — a release that raised may have leaked, and
an instance that may be holding resources it cannot account for must not
be reactivated." -/
def releaseCheck (e : InstState) (errors : Value) : PluginM Unit := do
  if errors.len == 0 then return
  e.status.set "failed"
  let why := String.intercalate "; " ((errors.items).map (·.asStr))
  raise "plugin_release_failed" ("release failed for " ++ e.ref ++ ": " ++ why)
    ((Value.vmap.set "ref" (.str e.ref)).set "cause" errors)

-- ---------------------------------------------------------------------
-- requirements and providers
-- ---------------------------------------------------------------------

def providersOf (h : HostState) (req : Value) : PluginM Value := do
  -- ASK WHETHER THE NAME IS A REF, do not assume it. A requirement name
  -- is a CAPABILITY name first (§11.1) and capability names are
  -- free-form, so `2fa` and `my cap` are legal ones that no ref could be
  -- called — and `canonRef` RAISES on those, which made a perfectly
  -- legal document kill the host right here.
  let rname := req.get "name"
  let asref := if rname.isStr then tryRef rname.asStr else none
  let mut cands : List Value := []
  for r in ← sortedRefs h do
    match ← findInst h r with
    | none => pure ()
    | some t =>
      if (← t.status.get) != "live" then continue
      let pos := .num (← t.pos.get)
      let cand := fun (prov : Value) =>
        ((Value.vmap.set "ref" (.str r)).set "pos" pos).set "provides" prov
      -- A ref satisfies directly.
      if asref == some r then cands := cands ++ [cand (Value.vmap.set "name" rname)]
      else
        for p in (← t.provides.get).items do
          if Value.same (p.get "name") rname then cands := cands ++ [cand p]
  resolveCapability req (.list cands)

def unmetOf (h : HostState) (e : InstState) : PluginM Value := do
  let mut out : List Value := []
  for r in (requirements (← e.options.get)).items do
    if !gatesActivation r then continue
    if (← providersOf h r).len == 0 then out := out ++ [r.get "name"]
  return .list out

/-- §11.4's always-reluctant selection, and the ONE place a provider is
chosen for a live instance. "A satisfied requirement is not re-bound
while it stays satisfied" is a statement about a REMEMBERED choice.

`remember` is false for the questions asked ABOUT an instance rather
than BY it — introspection must not create a binding. -/
def chosen (h : HostState) (e : InstState) (req : Value) (remember : Bool)
    : PluginM (Option String) := do
  let cands ← providersOf h req
  if cands.len == 0 then return none
  let name := (req.get "name").asStr
  let heldv := (← e.selected.get).get name
  if heldv.isStr && (cands.items).any (fun c => (c.get "ref").asStr == heldv.asStr) then
    return some heldv.asStr
  let first := ((cands.idx 0).get "ref").asStr
  if remember then e.selected.set ((← e.selected.get).set name (.str first))
  return some first

/-- The instance currently SELECTED for each of this one's
restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
capability (§11.1): the selected one going away restarts a `static`
consumer even though a survivor is available. -/
def boundProviders (h : HostState) (e : InstState) : PluginM (List String) := do
  let mut out : List String := []
  for r in (requirements (← e.options.get)).items do
    if !restartsOnLoss r then continue
    match ← chosen h e r false with
    | some p => if !out.contains p then out := out ++ [p]
    | none => pure ()
  return out

def consumersOf (h : HostState) (r : String) : PluginM (List String) := do
  let mut out : List String := []
  for c in ← sortedRefs h do
    if c == r then continue
    match ← findInst h c with
    | none => pure ()
    | some ci =>
      if (← ci.status.get) != "live" then continue
      if (← boundProviders h ci).contains r then out := out ++ [c]
  return out

/-- §11.3's `hold` asks a DIFFERENT question from the cascade.

The cascade wants the edges that RESTART — mandatory-static and
optional-static. `hold` says "deactivating a REQUIRED instance is
`plugin_dependency_held`", and `required` is CARDINALITY:
`gatesActivation`, not `restartsOnLoss`. The two sets differ in both
directions and each difference was a real bug. -/
def holdersOf (h : HostState) (r : String) : PluginM (List String) := do
  let mut out : List String := []
  for c in ← sortedRefs h do
    if c == r then continue
    match ← findInst h c with
    | none => pure ()
    | some ci =>
      if (← ci.status.get) != "live" then continue
      let mut hit := false
      for req in (requirements (← ci.options.get)).items do
        if !gatesActivation req then continue
        if (← chosen h ci req false) == some r then hit := true
      if hit then out := out ++ [c]
  return out

/-- The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
TEARDOWN. In a bulk operation that is removing the holders too, it is
suspended — otherwise `close()` under `hold` would raise on the first
provider it reached whenever a document happened to list a consumer
after it, which is the policy refusing the one teardown it has no reason
to object to. -/
def held (h : HostState) (e : InstState) : PluginM Unit := do
  if h.dependency != "hold" then return
  if ← h.coordinated.get then return
  let holders ← holdersOf h e.ref
  if holders.isEmpty then return
  raise "plugin_dependency_held" ("instance is required by live consumers: " ++ e.ref)
    ((Value.vmap.set "ref" (.str e.ref)).set "holders" (.list (holders.map Value.str)))

/-- The requirement graph as plain data, for the total detector. -/
def graphNodes (h : HostState) : PluginM Value := do
  let mut out : List Value := []
  for r in ← sortedRefs h do
    match ← findInst h r with
    | none => pure ()
    | some e =>
      let provs := ((← e.provides.get).items).map (fun p => p.get "name")
      out := out ++ [((Value.vmap.set "ref" (.str r)).set "provides" (.list provs)).set
        "requires" (requirements (← e.options.get))]
  return .list out

-- ---------------------------------------------------------------------
-- ordering and points
-- ---------------------------------------------------------------------

def hostOrder (h : HostState) (point : String) : PluginM Value := do
  -- Sorted by declaration SEQUENCE, which is what makes the §7 sort's
  -- fall-through deterministic in a language whose containers have no
  -- insertion order. §7 breaks ties by `pos`; two instances CAN share
  -- one — `declare` defaults `pos` to the registry size, so an unload
  -- followed by a fresh declare reuses a surviving instance's — and past
  -- that the canonical was falling through to map order. `seq` is that
  -- order, made explicit. Found by review of the go port.
  let all ← h.instances.get
  let mut live : List InstState := []
  for e in all do
    if (← e.status.get) == "live" then live := live ++ [e]
  let ordered := Value.sortWith (fun a b => a.seq ≤ b.seq) live
  let mut bindings : List Value := []
  for e in ordered do
    let b := (Value.vmap.set "ref" (.str e.ref)).set "pos" (.num (← e.pos.get))
    let ord ← e.order.get
    bindings := bindings ++ [if ord.isNull then b else b.set "order" ord]
  let spec := if point == "" then .null else h.points.get point
  resolveOrder (.list bindings) (if spec.isMap then spec.get "pin" else .null)

def positionOf (h : HostState) (r0 point : String) : PluginM Value := do
  let ranked ← hostOrder h point
  let r ← canonRefS r0
  let idx : Float := match (Value.indexed ranked.items).find? (fun p => p.1.asStr == r) with
    | some p => Float.ofNat p.2
    | none => -1.0
  let n := Float.ofNat ranked.len
  -- §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST, so
  -- these are not index 0 and count-1 the other way round. Getting this
  -- backwards is the exact error the positional pin vocabulary exists to
  -- prevent.
  return (((Value.vmap.set "index" (.num idx)).set "count" (.num n)).set
    "outermost" (.bool (idx == 0.0))).set "innermost" (.bool (idx == n - 1.0))

/-- Live bindings on a point, in resolved order. Recomputed on any change
to the live set (§7) rather than cached at startup — the bug a host
discovers only when something deactivates in production. -/
def boundOn (h : HostState) (point : String) : PluginM (List Bound) := do
  let ranked ← hostOrder h point
  let mut out : List Bound := []
  for rv in ranked.items do
    match ← findInst h rv.asStr with
    | none => pure ()
    | some e =>
      -- The band is the INSTANCE's ordering block (§7), stamped by the
      -- host. A plugin passing its own would be ranking itself above the
      -- order its document declared.
      let bandv := let x := (← e.order.get).get "band"; if x.isNum then x.asNum else 0.0
      for b in ← e.bindings.get do
        if b.point == point then out := out ++ [{ b with band := bandv }]
  return out

def pointSpec (h : HostState) (point : String) : PluginM Value := do
  if !h.points.has point then
    raise "plugin_point_unknown" ("no such point: " ++ point) (details1 "point" (.str point))
  let spec := h.points.get point
  return (if spec.isMap then spec else Value.vmap)

def checkKind (spec : Value) (point want : String) : PluginM Unit := do
  let kind := spec.get "kind"
  let given := kind.isStr
  let ok := if given then kind.asStr == want else want == "hook"
  if ok then return
  raise "plugin_point_kind" ("point is not a " ++ want ++ ": " ++ point)
    ((Value.vmap.set "point" (.str point)).set "kind" (if given then kind else .null))

/-- Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2). -/
partial def pointCall (bs : List Bound) (base : Option (Value → PluginM Value))
    (arg : Value) : PluginM Value :=
  match bs with
  | [] => match base with | some f => f arg | none => pure arg
  | b :: rest =>
    match b.chain with
    | some c => c (fun a => pointCall rest base a) arg
    | none => pointCall rest base arg

def hostEmit (h : HostState) (point : String) (arg : Value) : PluginM (Option Value) := do
  let spec ← pointSpec h point
  checkKind spec point "hook"
  let bindings ← boundOn h point
  let mode := let m := spec.get "mode"; if m.isStr then m.asStr else "emit"
  if mode == "bail" then
    -- Stops at the first binding that RETURNS A VALUE — the "handled,
    -- stop" case. `none`, AND A JSON NULL, BOTH DECLINE. JavaScript can
    -- tell null from undefined and almost nothing else in the target set
    -- can; §18's budget settles it (§6.1).
    for b in bindings do
      match b.hook with
      | none => pure ()
      | some f =>
        match ← f arg with
        | some x => if !x.isNull then return some x
        | none => pure ()
    return none
  let raising := mode == "emit"
  let mut errors : List Value := []
  for b in bindings do
    match b.hook with
    | none => pure ()
    | some f =>
      -- `emit` raises synchronously; the collecting modes gather.
      if raising then let _ ← f arg
      else
        try let _ ← f arg
        catch e =>
          errors := errors ++
            [(Value.vmap.set "code" (.str e.code)).set "message" (.str e.message)]
  if raising then return none else return some (.list errors)

def hostCall (h : HostState) (point : String) (arg : Value) : PluginM Value := do
  let spec ← pointSpec h point
  checkKind spec point "chain"
  let bindings ← boundOn h point
  -- The host owns the base and a plugin cannot replace it (§6.2). One
  -- that wants to SUBSTITUTE rather than wrap binds innermost and simply
  -- does not call `next`.
  pointCall bindings ((h.bases.find? (·.1 == point)).map (·.2)) arg

/-- At most one live implementation (§6.3). The winner is the highest
band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
silently ignored. -/
def rankProviders (bs : List Bound) (exclusive : Bool)
    : PluginM (Option Bound × Value) := do
  if bs.isEmpty then return (none, Value.vlist)
  if exclusive && bs.length > 1 then
    -- Sorted, so the message names the same pair whatever order the
    -- bindings arrived in.
    let refs := Value.sortWith Value.strLe (bs.map (·.ref))
    raise "plugin_point_exclusive"
      ("point is exclusive and has " ++ toString bs.length ++ " bindings: "
        ++ String.intercalate ", " refs)
      (details1 "refs" (.list (refs.map Value.str)))
  -- HIGHEST band wins, unlike hook and chain; ties break by ref sort,
  -- which is a TOTAL order.
  let ranked := Value.sortWith
    (fun a b => if a.band != b.band then a.band > b.band else Value.strLe a.ref b.ref) bs
  return (ranked.head?, .list ((ranked.drop 1).map (fun b => Value.str b.ref)))

def hostProvider (h : HostState) (point : String) (arg : Value) : PluginM (Option Value) := do
  let spec ← pointSpec h point
  checkKind spec point "provider"
  let bindings ← boundOn h point
  let (winner, _) ← rankProviders bindings (spec.get "exclusive").truthy
  match winner with
  | none => return some (spec.get "default")
  | some b => match b.hook with
    | some f => f arg
    | none => return none

def hostShadowed (h : HostState) (point : String) : PluginM Value := do
  if !h.points.has point then return Value.vlist
  let spec := h.points.get point
  let bindings ← boundOn h point
  let (_, sh) ← rankProviders bindings (spec.isMap && (spec.get "exclusive").truthy)
  return sh

def hostExports (h : HostState) (spec : String) : PluginM (Option Value) := do
  let mut all : List Value := []
  for r in ← sortedRefs h do
    match ← findInst h r with
    | none => pure ()
    | some e =>
      let st ← e.status.get
      -- Exports of a `loaded` (not live) instance are VISIBLE (§11).
      if st == "declared" || st == "failed" then continue
      let ex ← e.exports.get
      for k in ex.keys do
        all := all ++ [((Value.vmap.set "ref" (.str r)).set "key" (.str k)).set
          "value" (ex.get k)]
  resolveExport (.str spec) (.list all)

def hostCapability (h : HostState) (name : String) : PluginM Value := do
  let mut cands : List Value := []
  for r in ← sortedRefs h do
    match ← findInst h r with
    | none => pure ()
    | some e =>
      if (← e.status.get) != "live" then continue
      let pos := .num (← e.pos.get)
      for p in (← e.provides.get).items do
        if (p.get "name").isStr && (p.get "name").asStr == name then
          cands := cands ++
            [((Value.vmap.set "ref" (.str r)).set "pos" pos).set "provides" p]
  let ranked ← resolveCapability (Value.vmap.set "name" (.str name)) (.list cands)
  return .list ((ranked.items).map (fun c => c.get "ref"))

end Plugin
