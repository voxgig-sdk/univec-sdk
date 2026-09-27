-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Capability.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Version

/-!
# Capabilities (§11.1)

A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
dependency on something that can do the job, and which instance is doing
it is exactly the configuration detail a plugin must not care about.
(§11.1 makes one narrow exception for a ref, and `Host` implements it;
the ranking here is capabilities only.)

But A BINDING IS TO AN INSTANCE, not to a capability, which is what
decides behaviour when the bound provider leaves while another match
remains.
-/

namespace Plugin

/-- PARTIAL MATCH, RECURSING INTO MAPS (§11.1). THIS FUNCTION IS WHAT
"EVERY LEAF" MEANS, and an earlier draft of the canonical did not have
it: the check was a scalar compare, which for any compound value is
reference identity in JavaScript. A requirement and a capability are
declared in different places and are never the same object, so
`match: {limits: {max: 5}}` could not be satisfied by ANY provider —
including one declaring exactly that. Invisible while every corpus entry
is scalar, which is why the go port found it and P2 did not.

A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset — "the
first two of your three regions" is not something `match` can say. -/
partial def capMatchValue (want got : Value) : Bool :=
  if want.isMap then
    got.isMap && (want.keys).all (fun k => got.has k && capMatchValue (want.get k) (got.get k))
  else if want.isList then
    got.isList && want.len == got.len &&
      ((want.items).zip (got.items)).all (fun p => capMatchValue p.1 p.2)
  else Value.same want got

def capMatches (req prov : Value) : PluginM Bool := do
  if !Value.same (req.get "name") (prov.get "name") then return false
  let range := req.get "range"
  if !range.isNull then
    let version := prov.get "version"
    if version.isNull then return false
    if !(← satisfiesQ version range) then return false
  -- `match` is checked against the provider's `attrs`, key by key. A key
  -- the provider does not carry is a MISS, not a pass: a requirement
  -- asking for `transactional: true` must not be satisfied by a
  -- provider that never said.
  let m := req.get "match"
  if m.isNull then return true
  let attrs := let a := prov.get "attrs"; if a.isNull then Value.vmap else a
  return (m.keys).all (fun k => attrs.has k && capMatchValue (m.get k) (attrs.get k))

/-- The rank key for one candidate. THE KEYS ARE PRECOMPUTED because the
version comparison can raise and a comparator cannot: `parseVersion`
fails on a malformed version, and a comparator that swallowed that would
have to guess. Precomputing also makes the rank a TOTAL order on purpose
— without one, "any provider satisfies" is true of the GRAPH and useless
to the PLUGIN, and two ports could bind different `store` instances,
both resolve green, and behave differently. -/
structure RankKey where
  noVersion : Nat   -- a version beats none
  ver : List Float  -- negated, so HIGHEST version sorts first
  priority : Float  -- LOWEST priority first
  pos : Float
  cand : Value

def rankKey (c : Value) : PluginM RankKey := do
  let p := c.get "provides"
  let ver := p.get "version"
  let negated ←
    if ver.isNull then pure ([0.0, 0.0, 0.0] : List Float)
    else
      try
        let parsed ← parseVersion ver
        pure [-(parsed.idx 0).asNum, -(parsed.idx 1).asNum, -(parsed.idx 2).asNum]
      catch _ => pure [0.0, 0.0, 0.0]
  let pr := p.get "priority"
  return {
    noVersion := if ver.isNull then 1 else 0,
    ver := negated,
    priority := if pr.isNum then pr.asNum else 0.0,
    pos := (c.get "pos").asNum,
    cand := c }

def rankLe (a b : RankKey) : Bool :=
  if a.noVersion != b.noVersion then a.noVersion ≤ b.noVersion
  else
    let cmpv := ([0, 1, 2] : List Nat).foldl
      (fun (acc : Int) i =>
        if acc != 0 then acc
        else
          let x := a.ver.getD i 0.0
          let y := b.ver.getD i 0.0
          if x < y then -1 else if x > y then 1 else 0) 0
    if cmpv != 0 then cmpv < 0
    else if a.priority != b.priority then a.priority < b.priority
    else a.pos ≤ b.pos

/-- Rank the matching providers best-first: highest `version`, then
LOWEST `priority` (default 0), then declaration position `pos`
ascending. `candidates` is a list of `{ref, pos, provides}`. -/
def resolveCapability (req candidates : Value) : PluginM Value := do
  let mut hits : List RankKey := []
  for c in candidates.items do
    if ← capMatches req (c.get "provides") then
      hits := hits ++ [← rankKey c]
  return .list ((Value.sortWith rankLe hits).map (·.cand))

end Plugin
