-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Order.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Ref

/-!
# Ordering (§7) — one rule, one place

sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
and the third was not far off. This sort is the whole replacement, and
the tiers are in this order for a reason:

    1 constraints   before/after edges, by ref or by name
    2 bands         integer, lower first, default 0
    3 declaration   ties break by `pos`

CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
present. A band expresses a genuine cross-cutting layer; a constraint
expresses a relationship between two specific things; and a band chosen
by trial and error to fix an ordering bug is a bug wearing a number.
-/

namespace Plugin

/-- A NUMBER, not a numeric string. `order.band` accepting `"1"` was a
surviving mutation in more than one port: the corpus pins the type
because two ports disagreeing about whether `"1"` is a band is exactly
the divergence a shared corpus exists to remove. -/
private def bandOf (b : Value) : Float :=
  let x := (b.get "order").get "band"
  if x.isNum then x.asNum else 0.0

private def posOf (b : Value) : Float :=
  let x := b.get "pos"
  if x.isNum then x.asNum else 0.0

/-- Band first (lower runs first), then `pos` — the position the
DOCUMENT visibly states, not the order instances happened to load and
not the incarnation `seq`. -/
private def rankLe (a b : Value) : Bool :=
  if bandOf a != bandOf b then bandOf a < bandOf b else posOf a ≤ posOf b

/-- Was a constraint actually declared? An ABSENT one and an EMPTY LIST
are both "no constraint"; only a non-empty spelling is an edge. -/
private def declared (spec : Value) : Bool :=
  if spec.isList then spec.len > 0
  else if spec.isStr then spec.asStr != ""
  else false

/-- Matching is by REF, or by NAME across all of that definition's
instances (§7) — which is the whole reason the two spellings exist. -/
private def targets (spec nodes : Value) : List String :=
  let specs := if spec.isList then spec.items else [spec]
  specs.foldl
    (fun hit oneval =>
      if !oneval.isStr then hit
      else
        let one := oneval.asStr
        (nodes.items).foldl
          (fun h node =>
            let r := (node.get "ref").asStr
            if h.contains r then h
            else if r == one || refName r == one then h ++ [r]
            else h)
          hit)
    []

/-- A PIN IS NOT A CONSTRAINT (§7).

Constraints and bands are negotiable by definition — they are what
plugins and documents say they want, and the sort's job is to satisfy
them all. A pin is the host stating a structural invariant of its own
architecture, which is a different kind of claim and must not lose a tie
to a document.

So a pin PLACES the binding at the named end, and an ordering that would
move it away is `plugin_order_pinned` — rejected, not honoured into a
broken wrap. -/
private def applyPin (order : List String) (edges pin : Value) : PluginM (List String) := do
  if !pin.isMap then return order
  -- SORTED, not insertion order. A pin map is data — it can arrive from
  -- a host's own construction options in any order, and two names pinned
  -- to the same end are order-sensitive. Sorted is the one order every
  -- language agrees on, and `order/pin#two-names` pins it.
  let placed := (pin.sortedKeys).foldl
    (fun acc name =>
      match acc.find? (fun r => refName r == name) with
      | none => acc
      | some r =>
        -- `first`/`outermost` is index 0; `last`/`innermost` is the end.
        -- §6.2 makes the first chain binding outermost, which is why the
        -- vocabulary is positional and why the two spellings pair this
        -- way.
        let want := (pin.get name).asStr
        let rest := acc.filter (· != r)
        if want == "first" || want == "outermost" then r :: rest else rest ++ [r])
    order
  -- Now check that the placement did not break a constraint. This is the
  -- half that makes a pin a rejection rather than an override: the host
  -- wins on position, but it does not get to silently discard a
  -- relationship a plugin declared.
  let index := (Value.indexed placed).foldl (fun m p => m.set p.1 (.num (Float.ofNat p.2))) Value.vmap
  for from_ in edges.sortedKeys do
    for tov in (edges.get from_).items do
      let to := tov.asStr
      if (index.get from_).asNum > (index.get to).asNum then
        raise "plugin_order_pinned"
          ("a pin would move a binding an ordering constrains: " ++ from_ ++ " must precede " ++ to)
          (details2 "before" (.str from_) "after" (.str to))
  return placed

partial def resolveOrder (bindings pin : Value) : PluginM Value := do
  let nodes := bindings.items
  let byref := nodes.foldl (fun m b => m.set (b.get "ref").asStr b) Value.vmap

  -- Constraints are edges. A constraint naming an ABSENT binding is
  -- satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
  -- load in a host with no test plugin. That is sdkgen's __after__
  -- behaviour, kept.
  let edges := nodes.foldl
    (fun m b =>
      let bref := (b.get "ref").asStr
      let o := b.get "order"
      let m1 :=
        if declared (o.get "after") then
          (targets (o.get "after") bindings).foldl
            (fun mm x => mm.set x ((mm.get x).push (.str bref))) m
        else m
      if declared (o.get "before") then
        (targets (o.get "before") bindings).foldl
          (fun mm x => mm.set bref ((mm.get bref).push (.str x))) m1
      else m1)
    (nodes.foldl (fun m b => m.set (b.get "ref").asStr Value.vlist) Value.vmap)

  let indeg0 := (edges.keys).foldl
    (fun m from_ =>
      ((edges.get from_).items).foldl
        (fun mm tov =>
          let to := tov.asStr
          mm.set to (.num ((mm.get to).asNum + 1.0)))
        m)
    (nodes.foldl (fun m b => m.set (b.get "ref").asStr (.num 0.0)) Value.vmap)

  -- Stable topological sort.
  let rec topo (ready : List Value) (indeg : Value) (out : List String) : List String :=
    match Value.sortWith rankLe ready with
    | [] => out
    | next :: restReady =>
      let nref := (next.get "ref").asStr
      let (indeg', freed) := ((edges.get nref).items).foldl
        (fun (st : Value × List Value) tov =>
          let to := tov.asStr
          let d := (st.1.get to).asNum - 1.0
          let m := st.1.set to (.num d)
          (m, if d == 0.0 then st.2 ++ [byref.get to] else st.2))
        (indeg, [])
      topo (restReady ++ freed) indeg' (out ++ [nref])

  let ready0 := nodes.filter (fun b => (indeg0.get (b.get "ref").asStr).asNum == 0.0)
  let out := topo ready0 indeg0 []

  if out.length != nodes.length then
    let stuck := (nodes.map (fun b => (b.get "ref").asStr)).filter (fun r => !out.contains r)
    raise "plugin_order_cycle"
      ("before/after constraints cycle: " ++ String.intercalate " -> " stuck)
      (details1 "cycle" (.list (stuck.map Value.str)))

  return .list ((← applyPin out edges pin).map Value.str)

end Plugin
