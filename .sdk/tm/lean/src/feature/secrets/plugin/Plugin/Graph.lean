-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Graph.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Capability

/-!
# Whole-graph resolution (§11.4) — a phase, not a discovery

"Activate, and wait in `pending` if you must" is correct and, on its
own, produces a terrible experience: apply twenty instances against a
registry missing one thing and you get NINETEEN pending rows and no
statement of what is actually wrong.

`resolveGraph` is a PURE FUNCTION of the registry and the intended
activation set. No callbacks run, no state changes, nothing is touched.
It answers for the whole graph at once which instances can be live, and
for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.

The failure mode being designed against is a famous one: OSGi's resolver
is correct and its diagnostics are legendarily unusable. A resolver that
says "blocked" without saying WHY has moved the problem rather than
solved it, so `why` is part of the contract.
-/

namespace Plugin

private def sortedStrings (xs : List String) : Value :=
  .list ((Value.sortWith Value.strLe xs).map Value.str)

private def candidates (byref name : Value) : Value :=
  -- A NODE SATISFIES ITS OWN REF (§11.1), and this is where the graph
  -- learned it. Considering only declared capabilities made `resolve`
  -- answer `absent` about a provider sitting right there and live —
  -- §11.4's whole job is explaining the graph the runtime reconciles,
  -- and it was explaining a different one. Canonical (§4 rule 5), and
  -- tolerant, because a capability name need not be a well-formed ref.
  let asref := if name.isStr then tryRef name.asStr else none
  .list ((byref.sortedKeys).foldl
    (fun acc r =>
      let node := byref.get r
      let pos := let p := node.get "pos"; if p.isNum then p else .num 0.0
      let cand := fun (prov : Value) =>
        ((Value.vmap.set "ref" (node.get "ref")).set "pos" pos).set "provides" prov
      -- The ref match WINS OUTRIGHT for that node, as at runtime: one
      -- candidate, not two, for a node both named `b` and providing `b`
      -- — without the skip the blocked-chain explanation named it twice.
      if asref == some r then acc ++ [cand (Value.vmap.set "name" name)]
      else acc ++ ((node.get "provides").items.filter
        (fun p => Value.same (p.get "name") name)).map cand)
    [])

private def blockedOf (node unmet why : Value) : Value :=
  ((Value.vmap.set "ref" (node.get "ref")).set "unmet" unmet).set "why" why

private def why1 (kind : String) : Value := Value.vmap.set "kind" (.str kind)

/-- The FIRST unmet requirement, with the most specific explanation
available. Order matters: "no provider at all" and "a provider at the
wrong version" are different problems and a reader must not have to
guess which they have. -/
partial def firstUnmet (node byref resolved : Value) : PluginM (Option Value) := do
  for req in (node.get "requires").items do
    if (req.get "optional").truthy then continue
    let name := req.get "name"
    let all := candidates byref name
    if all.len == 0 then return some (blockedOf node name (why1 "absent"))
    let ok ← resolveCapability req all
    if ok.len > 0 then
      -- A provider exists and matches — but if none of them is itself
      -- resolved, this node is blocked BEHIND it, and the chain is the
      -- useful answer rather than "unmet".
      if (ok.items).any (fun c => resolved.has (c.get "ref").asStr) then continue
      let chain := (ok.items).map (fun c => (c.get "ref").asStr)
      return some (blockedOf node name ((why1 "blocked").set "chain" (sortedStrings chain)))
    -- Providers exist and none matched. Say which test failed.
    let range := req.get "range"
    if !range.isNull then
      let mut found : List String := []
      for c in all.items do
        let version := (c.get "provides").get "version"
        if version.isNull then found := found ++ ["(none)"]
        else if !(← satisfiesQ version range) then found := found ++ [version.asStr]
      if !found.isEmpty then
        return some (blockedOf node name
          (((why1 "version").set "range" range).set "found" (sortedStrings found)))
    let m := req.get "match"
    if !m.isNull then
      for c in all.items do
        let attrs := let a := (c.get "provides").get "attrs"; if a.isNull then Value.vmap else a
        for k in m.sortedKeys do
          -- The same recursive partial match the selection applies, so a
          -- nested requirement that FAILED the selection is also the one
          -- the diagnosis names (§11.4).
          if !attrs.has k || !capMatchValue (m.get k) (attrs.get k) then
            return some (blockedOf node name
              ((((why1 "match").set "failing" (.str k)).set "want" (m.get k)).set
                "found" (attrs.get k)))
    return some (blockedOf node name (why1 "absent"))
  return none

partial def resolveGraph (nodes : Value) : PluginM Value := do
  let byref := (nodes.items).foldl (fun m n => m.set (n.get "ref").asStr n) Value.vmap

  -- Fixed point: a node resolves when every mandatory requirement is met
  -- by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
  -- makes a provider that is itself blocked propagate, rather than each
  -- node being judged against the raw registry.
  let rec loop (resolved : Value) : PluginM Value := do
    let mut cur := resolved
    let mut moved := false
    for n in nodes.items do
      let r := (n.get "ref").asStr
      if cur.has r then continue
      if (← firstUnmet n byref cur).isNone then
        cur := cur.set r (.bool true)
        moved := true
    if moved then loop cur else return cur
  let resolved ← loop Value.vmap

  let mut blocked := Value.vmap
  for n in nodes.items do
    let r := (n.get "ref").asStr
    if resolved.has r then continue
    match ← firstUnmet n byref resolved with
    | some why => blocked := blocked.set r why
    | none => pure ()

  return (Value.vmap.set "resolved" (.list (resolved.sortedKeys.map Value.str))).set
    "blocked" (.list (blocked.sortedKeys.map (fun k => blocked.get k)))

end Plugin
