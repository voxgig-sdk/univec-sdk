-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Depend.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Ref

/-!
# Dependency cardinality, policy, and the restart graph (§11.3)

TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
because only it knows what it can cope with:

                 | static (default)          | dynamic
    -------------|---------------------------|--------------------------
    mandatory    | unmet -> pending;         | unmet -> pending;
    (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
                 |          recursively      |          notified
    -------------|---------------------------|--------------------------
    optional:true| never gates activation;   | never gates activation;
                 | a change deactivates and  | a change is a
                 | reactivates               | notification, nothing else

`dynamic` means the plugin has said, IN WRITING, that it can survive its
provider being swapped underneath it. It is not the default because most
plugins cannot, and the cost of wrongly assuming they can is a live
instance holding a dead reference.
-/

namespace Plugin

/-- A bare string is shorthand for `{name}`. -/
def normRequire (r : Value) : Value :=
  if r.isStr then Value.vmap.set "name" r
  else if r.isMap then r
  else Value.vmap

/-- BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.

The instance-level `policy` and `optional` list are how a DOCUMENT
states the axis without editing the definition, and they apply to every
requirement. The per-requirement form is strictly more expressive: an
instance that is `static` on its store and `dynamic` on its metrics
cannot be written at all at the instance level, and that is the ordinary
case rather than an exotic one.

`optional` UNIONS rather than overriding — both spellings say this
requirement need not gate activation, and there is no reading under
which one of them means "actually, mandatory". -/
def requirements (options : Value) : Value :=
  let marked := options.get "optional"
  let fallback := options.get "policy"
  .list (((options.get "requires").items).map (fun item =>
    let r := normRequire item
    let o := (r.keys).foldl (fun acc k => acc.set k (r.get k)) Value.vmap
    let opt := (r.get "optional").truthy ||
      (marked.isList && (marked.items).any (fun m => Value.same m (r.get "name")))
    let o1 := if opt then o.set "optional" (.bool true) else o
    if (o1.get "policy").isNull && !fallback.isNull then o1.set "policy" fallback else o1))

/-- Does losing this requirement's SELECTED provider restart the
consumer? The mandatory ones under `static`, and the `static` optional
ones — both make a capability change deactivate and reactivate.
`dynamic` never restarts. -/
def restartsOnLoss (r : Value) : Bool :=
  let p := r.get "policy"
  (if p.isStr then p.asStr else "static") != "dynamic"

/-- Does an unmet requirement keep the consumer out of `live`?

CARDINALITY ALONE DECIDES THIS, NOT POLICY. `dynamic` is a statement
about surviving a SWAP, not about starting without the thing at all — a
mandatory-dynamic consumer still waits in `pending` for its first
provider. Conflating the two would let a plugin that declared it can
cope with replacement activate with nothing to call. -/
def gatesActivation (r : Value) : Bool := (r.get "optional").asBool != true

/-- Edges that can cause a restart, which is exactly the set a cycle
must be detected over (§11.3): the mandatory requirements AND THE
`static` OPTIONAL ONES, because both make a capability change deactivate
and reactivate the consumer — and a cycle of restarts does not settle.

ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
exclusion was for. An earlier draft of §11.3 excluded EVERY optional
edge and thereby admitted the non-terminating case it was trying to
permit. -/
def restartCausing (r : Value) : Bool := gatesActivation r || restartsOnLoss r

inductive Colour where
  | white | grey | black
  deriving BEq, Inhabited

/-- `[{ref, provides:[name], requires:[req]}]` -> the cycle, or none. -/
partial def dependencyCycle (nodes : Value) : Option (List String) :=
  -- TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
  -- matched differently — a capability by its exact name, a ref through
  -- the canonical spelling (§4 rule 5) — and one map keyed by both can
  -- only do one of them. Keyed by both and looked up raw, a cycle
  -- spelled `a$`/`b$` finds no providers and EVADES the load-time check
  -- that exists to catch a non-terminating reconcile.
  let allRefs := (nodes.items).map (fun n => (n.get "ref").asStr)
  let byCap := (nodes.items).foldl
    (fun m n =>
      let nref := (n.get "ref").asStr
      ((n.get "provides").items).foldl
        (fun mm capv =>
          let c := capv.asStr
          let l := let x := mm.get c; if x.isList then x else Value.vlist
          mm.set c (l.push (.str nref)))
        m)
    Value.vmap
  let edges := (nodes.items).foldl
    (fun m n =>
      let nref := (n.get "ref").asStr
      let outs := ((n.get "requires").items).foldl
        (fun acc r =>
          if !restartCausing r then acc
          else
            let rname := (r.get "name").asStr
            let caps := ((byCap.get rname).items).map (·.asStr)
            -- A node satisfies its own name AS A REF (§11.1),
            -- canonically — exactly what `providersof` does at runtime,
            -- so the load-time graph and the running one agree about
            -- what an edge is.
            let froms := match tryRef rname with
              | some a => if allRefs.contains a && !caps.contains a then caps ++ [a] else caps
              | none => caps
            froms.foldl (fun a p => if p != nref && !a.contains p then a ++ [p] else a) acc)
        []
      m.set nref (.list ((Value.sortWith Value.strLe outs).map Value.str)))
    Value.vmap

  -- Iterative DFS with an explicit stack: twenty ports, and several of
  -- them have no recursion budget worth relying on.
  let rec walk (stack : List (String × Nat)) (path : List String) (colour : Value)
      : Option (List String) × Value :=
    match stack with
    | [] => (none, colour)
    | (tref, i) :: rest =>
      let tos := edges.get tref
      if i ≥ tos.len then
        walk rest (path.dropLast) (colour.set tref (.num 2.0))
      else
        let next := (tos.idx i).asStr
        let c := (colour.get next).asNum
        if c == 1.0 then
          -- Report the cycle itself, not the walk that found it.
          (some ((path.dropWhile (· != next)) ++ [next]), colour)
        else if c == 2.0 then walk ((tref, i + 1) :: rest) path colour
        else
          walk ((next, 0) :: (tref, i + 1) :: rest) (path ++ [next]) (colour.set next (.num 1.0))

  let rec search (starts : List String) (colour : Value) : Option (List String) :=
    match starts with
    | [] => none
    | s :: more =>
      if (colour.get s).asNum != 0.0 then search more colour
      else
        match walk [(s, 0)] [s] (colour.set s (.num 1.0)) with
        | (some c, _) => some c
        | (none, colour') => search more colour'

  search edges.sortedKeys (allRefs.foldl (fun m r => m.set r (.num 0.0)) Value.vmap)

/-- Raise on a cycle, naming it. Separate from the detector so the
detector stays total and corpus-testable. -/
def checkCycle (nodes : Value) : PluginM Unit := do
  match dependencyCycle nodes with
  | none => return
  | some cyc =>
    raise "plugin_dependency_cycle"
      ("requirements cycle: " ++ String.intercalate " -> " cyc)
      (details1 "cycle" (.list (cyc.map Value.str)))

end Plugin
