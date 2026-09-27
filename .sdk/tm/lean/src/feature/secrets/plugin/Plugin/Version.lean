-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Version.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Ref

/-!
# Versions and ranges (§11.2)

TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
concrete version. A requirement declares `range`. A requirement is
satisfied when the names match, the `match` passes, and the provider's
`version` falls inside the requirement's `range`. That is the whole rule
— there is no third field and no second comparison.
-/

namespace Plugin

/-- A COMPONENT IS BOUNDED, like a ref is (§4's 1024).

The grammar admits an unbounded digit sequence, and every language then
disagrees about what happens past its integer range: JavaScript silently
loses precision, Go's Atoi errors (and a port ignoring that gets 0), C
overflows, Python is exact, Haskell's `Integer` is unbounded — and so is
Lean's `Nat`, which is a fourth answer. `satisfies("0",
"9223372036854775808")` was false in the canonical and true in go, from
the same corpus.

2^31-1 because every port has a signed 32-bit integer, and no real
version has ever needed more. Stated rather than left to arithmetic
nobody agrees on. Found by review of the go port. -/
def componentMax : Nat := 2147483647

private def digitsOf (cs : List Char) : Nat :=
  cs.foldl (fun acc c => acc * 10 + (c.toNat - 48)) 0

private def isDig (c : Char) : Bool := '0' ≤ c && c ≤ '9'

/-- `^(\d+)(?:\.(\d+))?(?:\.(\d+))?$`, by hand: three components, digits
only, no leading sign, no empty component. Written out rather than
handed to a regex because the bound above has to be checked per
component anyway. Answers the three parts and whether any overflowed. -/
partial def parse3 (s : String) : Option (List Nat × Bool) :=
  let rec go (cs : List Char) (part : Nat) (acc : List Nat) : Option (List Nat × Bool) :=
    if part ≥ 3 then
      if cs.isEmpty then some (acc.reverse, acc.any (· > componentMax)) else none
    else if cs.isEmpty then
      if part > 0 then
        some ((acc.reverse ++ [0, 0, 0]).take 3, acc.any (· > componentMax))
      else none
    else
      let cs1 := if part > 0 then (match cs with | '.' :: r => some r | _ => none) else some cs
      match cs1 with
      | none => none
      | some r =>
        let ds := r.takeWhile isDig
        if ds.isEmpty then none
        else go (r.dropWhile isDig) (part + 1) (digitsOf ds :: acc)
  if s == "" then none else go s.toList 0 []

private def triple (ns : List Nat) : Value :=
  .list (ns.map (fun n => .num (Float.ofNat n)))

def parseRange (range : Value) : PluginM Value := do
  if !range.isStr || range.asStr == "" then
    raise "plugin_bad_range"
      ("invalid range: " ++ (if range.isStr then range.asStr else ""))
      (details1 "range" (if range.isNull then .null else range))
  let s := range.asStr
  -- Two forms and no more (§11.2):
  --   '2.1'   >= 2.1.0 and < 3.0.0
  --   '~2.1'  >= 2.1.0 and < 2.2.0
  let tilde := s.startsWith "~"
  let body := if tilde then (s.drop 1).toString else s
  match parse3 body with
  | none => raise "plugin_bad_range" ("invalid range: " ++ s) (details1 "range" range)
  | some (_, true) =>
    raise "plugin_bad_range" ("version component out of range in " ++ s)
      (details1 "range" range)
  | some (n, false) =>
    let a := n.getD 0 0
    let b := n.getD 1 0
    let c := n.getD 2 0
    let hi := if tilde then [a, b + 1, 0] else [a + 1, 0, 0]
    return (Value.vmap.set "lo" (triple [a, b, c])).set "hi" (triple hi)

def parseVersion (version : Value) : PluginM Value := do
  if !version.isStr then
    raise "plugin_bad_range" "invalid version"
      (details1 "version" (if version.isNull then .null else version))
  let s := version.asStr
  match parse3 s with
  -- `plugin_bad_range` either way — the same code the rest of the
  -- grammar's failures use, because "this is not a version I can
  -- compare" is one fact however it went wrong.
  | none => raise "plugin_bad_range" ("invalid version: " ++ s) (details1 "version" version)
  | some (_, true) =>
    raise "plugin_bad_range" ("version component out of range in " ++ s)
      (details1 "version" version)
  | some (n, false) => return triple n

def verCmp (a b : Value) : Int :=
  let step := fun (acc : Int) (i : Nat) =>
    if acc != 0 then acc
    else
      let x := (a.idx i).asNum
      let y := (b.idx i).asNum
      if x < y then -1 else if x > y then 1 else 0
  [0, 1, 2].foldl step 0

/-- The one satisfaction predicate: lo <= version < hi. -/
def satisfies (version range : Value) : PluginM Bool := do
  let v ← parseVersion version
  let r ← parseRange range
  return verCmp v (r.get "lo") ≥ 0 && verCmp v (r.get "hi") < 0

/-- The same, tolerant of a missing version — a bare ref carries none,
so `Graph` and `Depend` ask this rather than raising. -/
def satisfiesQ (version range : Value) : PluginM Bool :=
  try satisfies version range catch _ => return false

end Plugin
