/- The corpus test runner: the VENDORED @voxgig/omni port (test/vendor/omni/
   Omni.lean) driven through its NATIVE API (`Omni.makeRunnerSpec` /
   `RunPack.runsetflagsargs`), presented to the corpus suites in the shape
   they already use (`runspec`, `getset`, `runset`, `runsetArgs`, `report`).

   No compat shim is vendored: the adapter below IS the whole bridge, per
   language, per the vendor-tag rollout (docs/design/vendor-tag-rollout.md,
   Decision 4). It is the Lean peer of tm/ocaml/test/omni_resolver.ml and
   tm/java/test/OmniResolver.java — omni's provider is closure-based, so
   nothing in omni ever has to name this SDK's types.

   The engine used to live FUSED inside the two corpus suites: each carried
   its own JSON reader, fixJson, deep equality, matchval/doMatch,
   resolveArgs, checkResult, handleError and runSet. Both were rewritten in
   place onto this file, so both KEEP THEIR NAMES and no emitted call site
   needed churn — which is why nothing is listed as `superseded` for this
   target.

   Lean-specific decisions, each load-bearing:

   1. omni IS PURE, THIS SDK IS NOT. omni's `Subject` is
      `List Val → Except String Val`, a pure function; this SDK's struct port
      keeps its nodes in a heap threaded through `SIO` (a `ReaderT Ctx IO`),
      because Lean has no mutable value semantics. The subject callback is the
      one place the two meet, so it runs the action with `unsafeIO` — the
      escape hatch Lean provides for exactly this, and the same bridge
      voxgig/struct's own Lean corpus runner uses. TEST CODE ONLY: nothing
      under src/ names `runsio`.

   2. TWO VALUE MODELS, ONE CONVERSION PAIR. `Omni.Val` (`Option Lean.Json`)
      and `VoxgigStruct.Value` are different types, so every crossing is an
      explicit `tostruct` / `toomni`. omni's `none` (ABSENT) becomes this
      port's `.noval` and `Json.null` becomes `.null`, which keeps the two
      no-value states the corpus distinguishes apart — and is why Lean needs
      neither go's `novalargs` spec rewrite nor lua/php's compat shim for the
      corpus's ZERO-ARGUMENT entries. An entry with no `in`/`args`/`ctx`
      reaches the subject as one `Omni.Val` of `none`, which becomes exactly
      this port's own no-value, so `typify` answers T_NOVAL where a null
      would answer T_NULL.

   3. ARGUMENTS ARE WRITTEN BACK. `Omni.SubjectArgs` is the channel omni
      provides for a subject that MUTATES its arguments, which
      `match: {args: ...}` then asserts on — `struct/minor/setpath` (7
      entries here) and `struct/merge/integrity` (6) turn on it. Decision 2
      hands the subject a CONVERTED COPY on this SDK's heap, and `Lean.Json`
      is immutable, so every subject here runs through `runsetflagsargs` and
      the wrapper converts the (possibly mutated) values back into omni's
      own list after the call. A dynamic port's shim gets this free from
      shared object identity; Lean cannot.

   4. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
      A VALUE-SEMANTICS consequence, not a choice. omni's `drive` stores the
      contextified first argument as `entry.ctx` AND as `args[0]` — two
      copies of an immutable value — and `checkresult` reads `entry.ctx` for
      the ctx base. A subject's post-call writes (decision 3) can never reach
      that copy, and NINE `primary` entries assert exactly the post-call
      state (makeRequest, makeResponse, makeSpec, param, prepareAuth,
      resultBody, resultHeaders, transformRequest, transformResponse).
      `args[0]` IS the ctx of a ctx entry (omni itself sets
      `args = [entry.ctx]`), and the runner reads that list back after an
      args-subject call — so moving the assertion from `ctx` to `args.0`
      reads the SAME map, post-call, and preserves every leaf: nothing is
      dropped, weakened or skipped. `retargetctx` below does that rewrite on
      the spec handed to the engine. OCaml, Rust and Swift face the identical
      problem and answer it identically; the upstream fix is for the port's
      `drive` to re-point `entry.ctx` at the returned `args[0]`, the way JS
      object identity does implicitly — a follow-up, never a hand-edit of a
      vendored file.

   5. KEY ORDER. omni's Lean port models a map as `Lean.Json.obj`, whose
      container is key-SORTED (the vendored file says so itself), while this
      SDK's `Value` map is insertion-ordered. Every map in the shipped corpus
      is key-sorted, so the round trip is order-preserving in practice — and
      `Omni.deepequal` compares maps order-independently in any case. A
      corpus that ever ships an unsorted map would need the upstream fix
      (omni's own value model), never a hand-edit here.

   6. FAILURES ARE ACCUMULATED, NOT RAISED. omni stops a group at its first
      bad entry and returns the message; the corpus suites report the whole
      corpus in one run. `drive` records the message and carries on, so one
      run still names every broken GROUP. A group that is ABSENT from the
      corpus, or present with an empty set, is recorded in `skipped` and
      printed by `report` — named out loud, never a silent vacuous pass. -/

import VoxgigStruct
import Omni

open VoxgigStruct

namespace OmniResolver

-- ---------------- the sentinels, under the corpus's own names ----------

def nullmark : String := Omni.nullmark
def undefmark : String := Omni.undefmark
def existsmark : String := Omni.existsmark

-- ---------------- decision 1: the SIO <-> pure bridge ------------------

unsafe def runsioImpl {α : Type} [Inhabited α] (ctx : Ctx) (act : SIO α)
    : Except String α :=
  match unsafeIO (act.run ctx) with
  | .ok value => .ok value
  | .error err => .error err.toString

@[implemented_by runsioImpl]
opaque runsio {α : Type} [Inhabited α] (ctx : Ctx) (act : SIO α) : Except String α

-- ---------------- decision 2: the value models -------------------------

/-- omni's model -> this SDK's. Nodes are built through `newList` /
`emptyMap`, so what a subject receives is a real heap node it may rewrite in
place (decision 3). -/
partial def tostruct (value : Omni.Val) : SIO Value := do
  match value with
  | none => pure .noval
  | some .null => pure .null
  | some (.bool flag) => pure (.bool flag)
  | some (.num entry) => pure (.num entry.toFloat)
  | some (.str text) => pure (.str text)
  | some (.arr entries) => do
    let mut out : Array Value := #[]
    for entry in entries do
      out := out.push (← tostruct (some entry))
    newList out
  | some (.obj kvs) => do
    let m ← emptyMap
    for kv in kvs.toArray do
      let _ ← setprop m (.str kv.1) (← tostruct (some kv.2))
    pure m

/-- This SDK's model -> omni's. A function or a sentinel has no JSON form and
omni only ever stringifies one, so it becomes its own rendering rather than
silently collapsing to null — an unexpected one then FAILS visibly instead of
vanishing. -/
partial def toomni (value : Value) : SIO Omni.Val := do
  match value with
  | .noval => pure none
  | .null => pure (some Lean.Json.null)
  | .bool flag => pure (some (Lean.Json.bool flag))
  | .num n => pure (some (
      -- Whole values keep their integer spelling; anything else goes through
      -- the float constructor, which is the only lossless route Lean offers.
      if n == n.floor && n.abs < 9007199254740992.0 then
        Lean.Json.num (Lean.JsonNumber.fromInt (Int.ofNat n.abs.toUInt64.toNat
          |> fun m => if n < 0.0 then -m else m))
      else
        match Lean.JsonNumber.fromFloat? n with
        | .inr number => Lean.Json.num number
        | .inl _ => Lean.Json.null))
  | .str text => pure (some (Lean.Json.str text))
  | .list id => do
    let mut out : Array Lean.Json := #[]
    for item in (← listItems id) do
      out := out.push ((← toomni item).getD Lean.Json.null)
    pure (some (Lean.Json.arr out))
  | .map id => do
    let mut out : List (String × Lean.Json) := []
    for (k, v) in (← mapEntries id) do
      out := (k, (← toomni v).getD Lean.Json.null) :: out
    pure (some (Lean.Json.mkObj out.reverse))
  | .func _ => pure (some (Lean.Json.str "[Function]"))
  | .sentinel tag => pure (some (Lean.Json.str ("`$" ++ tag ++ "`")))

/-- Order-independent deep equality, through omni's own rule so a suite's
hand-written comparison matches the way every group is checked. -/
def eqv (a b : Value) : SIO Bool := do
  pure (Omni.deepequal (← toomni a) (← toomni b))

-- ---------------- value helpers (re-homed from the fused runners) ------

/-- Raw property read: a stored `null` is preserved, an absent key answers
`.noval`. NOT `SdkUtility.gp`, which collapses the two. -/
def getp (value : Value) (key : String) : SIO Value := do
  match value with
  | .map id => pure ((omapGet (← mapEntries id) key).getD .noval)
  | _ => pure .noval

def hasp (value : Value) (key : String) : SIO Bool := do
  match value with
  | .map id => pure (omapHas (← mapEntries id) key)
  | _ => pure false

def omapV (pairs : List (String × Value)) : SIO Value := do
  let m ← emptyMap
  for (key, value) in pairs do
    let _ ← setprop m (.str key) value
  pure m

/-- One of omni's arguments, absent answering `.noval`. -/
def arg (args : Array Value) (index : Nat) : Value := args[index]?.getD .noval

-- ---------------- the run ----------------------------------------------

/-- One corpus run: the engine's pack, plus the accumulated tally
(decision 6). The counters are `IO.Ref`s because a Lean structure is
immutable and every suite drives dozens of groups in sequence. -/
structure Run where
  pack : Omni.RunPack
  pass : IO.Ref Nat
  groups : IO.Ref Nat
  failures : IO.Ref (Array String)
  skipped : IO.Ref (Array String)

/-- Every provider hook is optional and this SDK needs none of them: subjects
are passed explicitly per group (so `subject` is unused), no suite builds a
client from a corpus `DEF.client` block (so `client` is unused), contexts stay
maps across the runner (decision 4, so `contextify` is unused), and no corpus
entry asserts on an error CODE, so omni's own {name,message} errify is exactly
right. -/
def provider : Omni.Provider := Omni.emptyProvider

def makeRunSpec (alltests : Lean.Json) (name : String) : IO Run := do
  let pack ← match Omni.makeRunnerSpec alltests provider name with
    | .ok pack => pure pack
    | .error message => throw (IO.userError message)
  let pass ← IO.mkRef 0
  let groups ← IO.mkRef 0
  let failures ← IO.mkRef (#[] : Array String)
  let skipped ← IO.mkRef (#[] : Array String)
  pure { pack, pass, groups, failures, skipped }

def makeRun (testfile : String) (name : String) : IO Run := do
  makeRunSpec (← Omni.loadspec testfile) name

/-- Where the shared corpus lives: the first command-line argument, else
$SDK_TEST_SPEC, else the usual relative positions. The first candidate is the
fallback so a missing file is reported by name. -/
def specCandidates : Array String :=
  #["../.sdk/test/test.json", ".sdk/test/test.json", "test/test.json"]

def resolveSpecPath (argv : List String) : IO String := do
  match argv.head? with
  | some given => pure given
  | none =>
    match (← IO.getEnv "SDK_TEST_SPEC") with
    | some given => pure given
    | none => do
      for candidate in specCandidates do
        if ← System.FilePath.pathExists candidate then
          return candidate
      pure specCandidates[0]!

/-- The resolved section of the spec (omni's `primary.<name>`, then `<name>`,
then the whole spec). -/
def runspec (r : Run) : Lean.Json := r.pack.spec

/-- A named group, by a path of keys from the resolved section. -/
def getset (r : Run) (keys : List String) : Omni.Val :=
  keys.foldl (fun acc key => Omni.jget acc key) (some r.pack.spec)

/-- A corpus group authored as ONE `{in, out}` pair rather than a set —
`merge/basic`, `inject/basic`, `transform/basic`, `walk/log`. Wrapped into a
one-entry set so it runs through the SAME engine as everything else instead of
a bespoke code path beside it. `out` selects a sub-path of the authored `out`
(walk/log asserts only on `out.after`). -/
def single (node : Omni.Val) (out : List String := []) : Omni.Val :=
  let expected := out.foldl (fun acc key => Omni.jget acc key) (Omni.jget node "out")
  some (Omni.jmap [("set", Omni.jlist [
    Omni.jmap [("in", (Omni.jget node "in").getD Lean.Json.null),
               ("out", expected.getD Lean.Json.null)]])])

-- ---------------- decision 4: retarget match.ctx -----------------------

def retargetctx (testspec : Lean.Json) : Lean.Json :=
  match Omni.aslist (Omni.jget (some testspec) "set") with
  | none => testspec
  | some entries =>
    let rewrite (raw : Lean.Json) : Lean.Json :=
      let check := Omni.jget (some raw) "match"
      if Omni.ismap (some raw) && Omni.ismap check && Omni.jhas check "ctx"
          && !Omni.jhas check "args"
          && (Omni.jhas (some raw) "ctx" || Omni.jhas (some raw) "args") then
        -- Drop the original leaf: it would read the stale pre-call copy omni
        -- keeps in `entry.ctx`.
        let kept := ((Omni.asmap check).getD []).filter (fun kv => kv.1 != "ctx")
        let leaf := (Omni.jget check "ctx").getD Lean.Json.null
        Omni.jset raw "match"
          (Omni.jmap (kept ++ [("args", Omni.jmap [("0", leaf)])]))
      else raw
    Omni.jset testspec "set" (Lean.Json.arr (entries.map rewrite))

-- ---------------- driving one group ------------------------------------

def entrycount (node : Omni.Val) : Int :=
  match Omni.aslist (Omni.jget node "set") with
  | some entries => (entries.size : Int)
  | none => -1

def oneline (text : String) : String :=
  String.intercalate " | " (text.splitOn "\n")

def drive (r : Run) (nullflag : Bool) (label : String) (node : Omni.Val)
    (call : Omni.SubjectArgs) : IO Unit := do
  let count := entrycount node
  if count <= 0 then
    -- Absent, malformed, or empty. NAMED, never silent: a group that stopped
    -- running is the failure mode the vendored engine exists to prevent.
    let why :=
      if Omni.isabsent node then "absent from corpus"
      else if count == 0 then "empty set" else "no set"
    r.skipped.modify (·.push s!"{label} ({why})")
  else do
    r.groups.modify (· + 1)
    match r.pack.runsetflagsargs (retargetctx (node.getD Lean.Json.null))
        { null := nullflag, name := some label } call with
    | .ok () => r.pass.modify (· + count.toNat)
    | .error message => r.failures.modify (·.push (oneline message))

/-- The subject wrapper: convert in, call, convert the (possibly mutated)
arguments and the result back out (decisions 1, 2 and 3). -/
def wrapArgs (ctx : Ctx) (subject : Array Value → SIO Value) : Omni.SubjectArgs :=
  fun cells =>
    runsio ctx (do
      let mut vals : Array Value := #[]
      for cell in cells do
        vals := vals.push (← tostruct cell)
      let res ← subject vals
      let mut back : Array Omni.Val := #[]
      for value in vals do
        back := back.push (← toomni value)
      pure (back.toList, ← toomni res))

/-- Run one group whose subject takes omni's whole argument list. This is the
shape the `primary` suite needs: a `ctx` entry arrives as `args[0]`, a MAP,
which the call site turns into a live context and writes the observable state
back into (decisions 3 and 4). -/
def runsetArgs (r : Run) (label : String) (node : Omni.Val)
    (subject : Array Value → SIO Value) (nullflag : Bool := true) : SIO Unit := do
  drive r nullflag label node (wrapArgs (← read) subject)

/-- Run one group whose subject takes the entry's single argument. -/
def runset (r : Run) (label : String) (node : Omni.Val)
    (subject : Value → SIO Value) (nullflag : Bool := true) : SIO Unit :=
  runsetArgs r label node (fun vals => subject (arg vals 0)) nullflag

-- ---------------- reporting --------------------------------------------

def report (r : Run) (heading : String) : IO UInt32 := do
  for message in (← r.failures.get) do
    IO.println ("FAIL " ++ message)
  for note in (← r.skipped.get) do
    IO.println ("SKIP " ++ note)
  let passed ← r.pass.get
  let grouped ← r.groups.get
  let failed := (← r.failures.get).size
  let skips := (← r.skipped.get).size
  IO.println ""
  IO.println s!"{heading}PASS {passed}  FAIL {failed}"
  IO.println s!"{heading}GROUPS {grouped}  SKIPPED {skips}"
  -- A run that executes nothing is not a pass.
  if passed == 0 then do
    IO.println (heading ++ "the corpus executed no cases")
    return 1
  if 0 < failed then return 1
  return 0

end OmniResolver
