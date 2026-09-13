/- Univec SDK omni runner smoke test.

   Smoke tests for the VENDORED @voxgig/omni engine itself
   (test/vendor/omni/Omni.lean), and for the load-bearing decisions in
   OmniResolver. A runner that cannot FAIL a bad entry would turn every
   corpus suite vacuously green, so the FAILURE paths are pinned here, not
   just the happy one. (Lean peer of ocaml's test/omni_smoke_test.ml, ts's
   test/omni.test.ts and lua's test/omni_smoke_test.lua.)

   The spec is built IN MEMORY, in omni's own value model — no fixture file,
   and no OMNI block (lenient v0, like the shared corpus). -/

import VoxgigStruct
import Omni
import OmniResolver

open VoxgigStruct
open OmniResolver

-- ---------------- a tiny assertion harness ----------------

initialize npass : IO.Ref Nat ← IO.mkRef 0
initialize nfail : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (cond : Bool) : IO Unit := do
  if cond then npass.modify (· + 1)
  else do
    nfail.modify (· + 1)
    IO.println ("FAIL " ++ name)

def contains (hay needle : String) : Bool :=
  needle.isEmpty || 1 < (hay.splitOn needle).length

/-- Exactly one recorded failure, and it names `want`. -/
def onefailure (name : String) (r : Run) (want : String) : IO Unit := do
  let msgs ← r.failures.get
  if msgs.size == 1 then
    check (name ++ ": failure mentions " ++ want) (contains (msgs[0]?.getD "") want)
  else
    check (name ++ ": expected exactly one failure, got " ++ toString msgs.size) false

-- ---------------- the in-memory spec ----------------

def num (n : Int) : Lean.Json := Omni.jnum n

def makespec : Lean.Json :=
  Omni.jmap [("primary", Omni.jmap [("smoke", Omni.jmap [

    ("basic", Omni.jmap [("set", Omni.jlist [
      Omni.jmap [("in", num 1), ("out", num 2)],
      Omni.jmap [("in", num 41), ("out", num 42)]])]),

    ("bad", Omni.jmap [("set", Omni.jlist [
      Omni.jmap [("in", num 1), ("out", num 999)]])]),

    ("err", Omni.jmap [("set", Omni.jlist [
      Omni.jmap [("in", num 0), ("err", Omni.jstr "zero refused")]])]),

    ("empty", Omni.jmap [("set", Omni.jlist [])]),

    -- Resolver decision 3: a subject that MUTATES its argument, which
    -- `match.args` then asserts on. Without the write-back this passes
    -- vacuously — the assertion would read the unmutated input.
    ("mutate", Omni.jmap [("set", Omni.jlist [
      Omni.jmap [("in", Omni.jmap [("x", num 1)]),
                 ("match", Omni.jmap [("args", Omni.jmap [("0", Omni.jmap [("x", num 2)])])]),
                 ("out", num 2)]])]),

    -- Resolver decision 4: `match: {ctx: ...}` must read the POST-call ctx.
    -- omni's own `entry.ctx` is a pre-call copy, so without the retarget
    -- this entry fails.
    ("ctx", Omni.jmap [("set", Omni.jlist [
      Omni.jmap [("ctx", Omni.jmap [("a", num 1)]),
                 ("match", Omni.jmap [("ctx", Omni.jmap [("b", num 2)])]),
                 ("out", num 1)]])])

  ])])]

def pack : IO Run := makeRunSpec makespec "smoke"

-- ---------------- subjects ----------------

def inc (v : Value) : SIO Value := do
  match v with
  | .num n => if n == 0.0 then throw (IO.userError "smoke: zero refused")
              else pure (.num (n + 1.0))
  | other => pure other

def identity (v : Value) : SIO Value := pure v

/-- Mutates its argument in place and returns the new value. -/
def bump (v : Value) : SIO Value := do
  let _ ← setprop v (.str "x") (.num 2.0)
  pure (.num 2.0)

/-- Does NOT mutate: the negative control for decision 3. -/
def nobump (_v : Value) : SIO Value := pure (.num 2.0)

/-- Writes a key onto the ctx map AFTER it was handed over: the positive
control for decision 4. -/
def ctxwrite (args : Array Value) : SIO Value := do
  let _ ← setprop (arg args 0) (.str "b") (.num 2.0)
  pure (.num 1.0)

def ctxnowrite (_args : Array Value) : SIO Value := pure (.num 1.0)

-- ---------------- the tests ----------------

def main : IO UInt32 := do
  let sctx ← mkCtx

  -- A correct subject passes, and every case is counted.
  let r ← pack
  (runset r "basic" (getset r ["basic"]) inc).run sctx
  check "basic: no failures" (← r.failures.get).isEmpty
  check "basic: both cases ran" ((← r.pass.get) == 2)
  check "basic: one group driven" ((← r.groups.get) == 1)

  -- A wrong result FAILS, and the resolver records it rather than swallowing
  -- it. This is the anti-vacuity check the whole rollout exists for.
  let r ← pack
  (runset r "bad" (getset r ["bad"]) inc).run sctx
  onefailure "bad" r "result mismatch"
  check "bad: no case counted as passing" ((← r.pass.get) == 0)

  -- An expected error is matched.
  let r ← pack
  (runset r "err" (getset r ["err"]) inc).run sctx
  check "err: expected error matched" (← r.failures.get).isEmpty
  check "err: case counted" ((← r.pass.get) == 1)

  -- An expected error that does NOT occur must fail.
  let r ← pack
  (runset r "err" (getset r ["err"]) identity).run sctx
  onefailure "err-missing" r "expected error did not occur"

  -- A group absent from the spec is NAMED, never a silent pass.
  let r ← pack
  (runset r "nosuch" (getset r ["nosuch"]) inc).run sctx
  check "absent: no failures" (← r.failures.get).isEmpty
  check "absent: nothing counted" ((← r.pass.get) == 0)
  check "absent: named as skipped" ((← r.skipped.get).size == 1)

  -- An EMPTY set is likewise named, not counted as a pass.
  let r ← pack
  (runset r "empty" (getset r ["empty"]) inc).run sctx
  check "empty: nothing counted" ((← r.pass.get) == 0)
  check "empty: named as skipped" ((← r.skipped.get).size == 1)

  -- Decision 3: argument mutation reaches `match.args`.
  let r ← pack
  (runset r "mutate" (getset r ["mutate"]) bump).run sctx
  check "mutate: write-back reaches match.args" (← r.failures.get).isEmpty
  check "mutate: case counted" ((← r.pass.get) == 1)

  let r ← pack
  (runset r "mutate" (getset r ["mutate"]) nobump).run sctx
  onefailure "mutate-missing" r "match failed at args.0.x"

  -- Decision 4: `match.ctx` reads the POST-call ctx.
  let r ← pack
  (runsetArgs r "ctx" (getset r ["ctx"]) ctxwrite).run sctx
  check "ctx: retarget reaches post-call ctx" (← r.failures.get).isEmpty
  check "ctx: case counted" ((← r.pass.get) == 1)

  let r ← pack
  (runsetArgs r "ctx" (getset r ["ctx"]) ctxnowrite).run sctx
  onefailure "ctx-missing" r "match failed at args.0.b"

  let p ← npass.get
  let f ← nfail.get
  IO.println ""
  IO.println s!"OMNI SMOKE: PASS {p}  FAIL {f}"
  if f > 0 then return 1 else return 0
