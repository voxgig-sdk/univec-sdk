/- Univec SDK primary utility test.

   Drives the SHARED language-neutral corpus (.sdk/test/test.json, section
   `primary`) — the same fixtures every other target executes — so this suite
   cannot drift from the reference implementation. Each section is looked up
   with `getSpec` and executed with `runset`, as the ts/js reference harness
   does. -/

import VoxgigStruct
import Vregex
import SdkJson
import SdkUtility
import SdkConfig

open VoxgigStruct

initialize npass : IO.Ref Nat ← IO.mkRef 0
initialize nfail : IO.Ref Nat ← IO.mkRef 0
initialize failures : IO.Ref (Array String) ← IO.mkRef #[]

def pass : SIO Unit := do npass.modify (· + 1)

def fail (msg : String) : SIO Unit := do
  nfail.modify (· + 1)
  failures.modify (·.push msg)

-- ---------------------------------------------------------------------------
-- corpus navigation
-- ---------------------------------------------------------------------------

/-- Navigate into the nested corpus map by keys. -/
def getSpec (root : Value) (path : Array String) : SIO Value := do
  let mut cur := root
  for k in path do
    cur ← SdkUtility.gp cur k
  pure cur

def itemsOf (v : Value) : SIO (Array Value) := do
  match v with
  | .list i => listItems i
  | _ => pure #[]

def argAt (args : Value) (i : Nat) : SIO Value := do
  pure ((← itemsOf args)[i]?.getD .noval)

-- ---------------------------------------------------------------------------
-- comparison
-- ---------------------------------------------------------------------------

/-- Deep structural equality; an empty list and an empty map are equivalent. -/
partial def deepEq (a b : Value) : SIO Bool := do
  match a, b with
  | .map ia, .map ib => do
    let ka ← keysof (.map ia)
    let kb ← keysof (.map ib)
    if ka.size != kb.size then pure false
    else do
      let mut ok := true
      for k in ka do
        let va ← SdkUtility.gp (.map ia) k
        let vb ← SdkUtility.gp (.map ib) k
        if !(← deepEq va vb) then ok := false
      pure ok
  | .list ia, .list ib => do
    let la ← listItems ia
    let lb ← listItems ib
    if la.size != lb.size then pure false
    else do
      let mut ok := true
      for i in [0:la.size] do
        if !(← deepEq (la[i]!) (lb[i]!)) then ok := false
      pure ok
  | .map ia, .list ib => do
    pure ((← keysof (.map ia)).isEmpty && (← listItems ib).isEmpty)
  | .list ia, .map ib => do
    pure ((← listItems ia).isEmpty && (← keysof (.map ib)).isEmpty)
  | x, y => pure (x == y)

/-- A corpus string check: `/re/` is a regex, otherwise substring containment. -/
def strCheck (checkStr subject : String) : Bool :=
  if checkStr.length > 1 && checkStr.startsWith "/" && checkStr.endsWith "/" then
    let inner := String.ofList (checkStr.toList.drop 1).dropLast
    Vregex.testStr inner subject
  else if checkStr == subject then true
  else (subject.splitOn checkStr).length > 1

/-- Partial deep match: every key present in `check` must hold in `base`. -/
partial def matchDeep (check base : Value) (path : String) (errs : IO.Ref (Array String)) :
    SIO Unit := do
  match check with
  | .map ic =>
    for k in (← keysof (.map ic)) do
      let cv ← SdkUtility.gp (.map ic) k
      let bv ← SdkUtility.gp base k
      matchDeep cv bv (if path == "" then k else path ++ "." ++ k) errs
  | .list ic => do
    let items ← listItems ic
    let bitems ← itemsOf base
    for i in [0:items.size] do
      let bv := bitems[i]?.getD .noval
      matchDeep (items[i]!) bv (path ++ "[" ++ toString i ++ "]") errs
  | .str s =>
    if s == "__EXISTS__" then
      (if SdkUtility.isNov base then errs.modify (·.push (path ++ ": expected to exist")) else pure ())
    else if s == "__UNDEF__" then
      (if SdkUtility.isNov base then pure () else errs.modify (·.push (path ++ ": expected undefined")))
    else do
      let bs := SdkUtility.vs base
      if strCheck s bs then pure ()
      else errs.modify (·.push (path ++ ": want " ++ s ++ ", got " ++ bs))
  | _ => do
    if (← deepEq check base) then pure ()
    else do
      let cs ← stringify check
      let bs ← stringify base
      errs.modify (·.push (path ++ ": want " ++ cs ++ ", got " ++ bs))

-- ---------------------------------------------------------------------------
-- the runner
-- ---------------------------------------------------------------------------

abbrev Subject := Value → SIO (Value × Option Value)

def runset (secname : String) (spec : Value) (subject : Subject) : SIO Unit := do
  let entries ← itemsOf (← SdkUtility.gp spec "set")
  for idx in [0:entries.size] do
    let entry := entries[idx]!
    let label := secname ++ "[" ++ toString idx ++ "]"
    let errs ← IO.mkRef (#[] : Array String)
    let (res, merr) ← subject entry
    let expErr ← SdkUtility.gp entry "err"
    let mspec ← SdkUtility.gp entry "match"
    match merr with
    | some e => do
      let em ← SdkUtility.gpS e "message"
      if SdkUtility.isNov expErr then fail (label ++ ": unexpected error: " ++ em)
      else do
        let ok := match expErr with
          | .str s => strCheck s em
          | .bool b => b
          | _ => false
        if !ok then fail (label ++ ": error mismatch: got " ++ em)
        else do
          if !(SdkUtility.isNov mspec) then do
            let rm ← emptyMap
            let emap ← newMap #[("message", .str em)]
            SdkUtility.sp rm "err" emap
            SdkUtility.sp rm "out" res
            matchDeep mspec rm "" errs
          let es ← errs.get
          if es.isEmpty then pass else fail (label ++ ": " ++ String.intercalate "; " es.toList)
    | none => do
      if !(SdkUtility.isNov expErr) then fail (label ++ ": expected an error, got a result")
      else do
        if !(SdkUtility.isNov mspec) then do
          let rm ← emptyMap
          SdkUtility.sp rm "out" res
          SdkUtility.sp rm "in" (← SdkUtility.gp entry "in")
          SdkUtility.sp rm "ctx" (← SdkUtility.gp entry "ctx")
          SdkUtility.sp rm "args" (← SdkUtility.gp entry "args")
          matchDeep mspec rm "" errs
        let expOut ← SdkUtility.gp entry "out"
        if !(SdkUtility.isNov expOut) then
          if !(← deepEq expOut res) then do
            let rs ← stringify res
            let os ← stringify expOut
            errs.modify (·.push ("out: want " ++ os ++ ", got " ++ rs))
        let es ← errs.get
        if es.isEmpty then pass else fail (label ++ ": " ++ String.intercalate "; " es.toList)

-- ---------------------------------------------------------------------------
-- context construction
-- ---------------------------------------------------------------------------

/-- The entry's own `ctx` map (created and attached when absent), wired to the
    client options/config so the utilities see them. -/
def entryCtx (entry options config : Value) : SIO Value := do
  let ctx ← match (← SdkUtility.gp entry "ctx") with
    | .map i => pure (Value.map i)
    | _ => do
      let m ← emptyMap
      SdkUtility.sp entry "ctx" m
      pure m
  SdkUtility.sp ctx "options" options
  SdkUtility.sp ctx "config" config
  pure ctx

/-- A ctx from a bare map (args-style sections); published back onto the entry
    as `ctx` so a `match: ctx:` assertion sees the mutated context. -/
def mapCtx (entry v options config : Value) : SIO Value := do
  let ctx ← match v with
    | .map i => pure (Value.map i)
    | _ => emptyMap
  SdkUtility.sp ctx "options" options
  SdkUtility.sp ctx "config" config
  SdkUtility.sp entry "ctx" ctx
  pure ctx

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

def specPaths : Array String :=
  #["../.sdk/test/test.json", ".sdk/test/test.json", "test/test.json"]

def readSpecFile : IO String := do
  match (← IO.getEnv "SDK_TEST_SPEC") with
  | some p => IO.FS.readFile p
  | none => do
    for p in specPaths do
      if ← System.FilePath.pathExists p then
        return (← IO.FS.readFile p)
    throw (IO.userError "cannot find .sdk/test/test.json (set SDK_TEST_SPEC)")

def main : IO UInt32 := do
  let raw ← readSpecFile
  let sctx ← mkCtx
  let go : SIO Unit := do
    let root ← SdkJson.jsonRead raw
    let primary ← SdkUtility.gp root "primary"
    let config ← SdkJson.jsonRead SdkConfig.configJson
    let opts ← SdkUtility.makeOptions config (← emptyMap)

    runset "done" (← getSpec primary #["done", "basic"]) fun entry => do
      SdkUtility.done (← entryCtx entry opts config)

    runset "makeContext" (← getSpec primary #["makeContext", "basic"]) fun entry => do
      let ctx ← mapCtx entry (← SdkUtility.gp entry "in") opts config
      pure ((← SdkUtility.makeContext ctx), none)

    runset "makeError" (← getSpec primary #["makeError", "basic"]) fun entry => do
      let args ← SdkUtility.gp entry "args"
      let ctx ← mapCtx entry (← argAt args 0) opts config
      pure (.noval, some (← SdkUtility.makeError ctx (← argAt args 1)))

    runset "makeOptions" (← getSpec primary #["makeOptions", "basic"]) fun entry => do
      let inv ← SdkUtility.gp entry "in"
      pure ((← SdkUtility.makeOptions (← SdkUtility.gp inv "config") (← SdkUtility.gp inv "options")), none)

    runset "makeRequest" (← getSpec primary #["makeRequest", "basic"]) fun entry => do
      SdkUtility.makeRequest (← entryCtx entry opts config)

    runset "makeResponse" (← getSpec primary #["makeResponse", "basic"]) fun entry => do
      SdkUtility.makeResponse (← entryCtx entry opts config)

    let specOpts ← SdkUtility.makeOptions config (← getSpec primary #["makeSpec", "DEF", "setup", "a"])
    runset "makeSpec" (← getSpec primary #["makeSpec", "basic"]) fun entry => do
      SdkUtility.makeSpec (← entryCtx entry specOpts config)

    runset "makeUrl" (← getSpec primary #["makeUrl", "basic"]) fun entry => do
      SdkUtility.makeUrl (← entryCtx entry opts config)

    runset "operator" (← getSpec primary #["operator", "basic"]) fun entry => do
      pure ((← SdkUtility.operator (← SdkUtility.gp entry "in")), none)

    runset "param" (← getSpec primary #["param", "basic"]) fun entry => do
      let args ← SdkUtility.gp entry "args"
      let ctx ← mapCtx entry (← argAt args 0) opts config
      pure ((← SdkUtility.param ctx (← argAt args 1)), none)

    let authOpts ← SdkUtility.makeOptions config (← getSpec primary #["prepareAuth", "DEF", "setup", "a"])
    runset "prepareAuth" (← getSpec primary #["prepareAuth", "basic"]) fun entry => do
      SdkUtility.prepareAuth (← entryCtx entry authOpts config)

    runset "prepareBody" (← getSpec primary #["prepareBody", "basic"]) fun entry => do
      pure ((← SdkUtility.prepareBody (← entryCtx entry opts config)), none)

    runset "prepareHeaders" (← getSpec primary #["prepareHeaders", "basic"]) fun entry => do
      pure ((← SdkUtility.prepareHeaders (← entryCtx entry opts config)), none)

    runset "prepareMethod" (← getSpec primary #["prepareMethod", "basic"]) fun entry => do
      let m ← SdkUtility.prepareMethod (← entryCtx entry opts config)
      pure (.str m, none)

    runset "prepareParams" (← getSpec primary #["prepareParams", "basic"]) fun entry => do
      pure ((← SdkUtility.prepareParams (← entryCtx entry opts config)), none)

    runset "preparePath" (← getSpec primary #["preparePath", "basic"]) fun entry => do
      let p ← SdkUtility.preparePath (← entryCtx entry opts config)
      pure (.str p, none)

    runset "prepareQuery" (← getSpec primary #["prepareQuery", "basic"]) fun entry => do
      pure ((← SdkUtility.prepareQuery (← entryCtx entry opts config)), none)

    runset "resultBasic" (← getSpec primary #["resultBasic", "basic"]) fun entry => do
      let ctx ← entryCtx entry opts config
      SdkUtility.resultBasic ctx
      pure ((← SdkUtility.gp ctx "result"), none)

    runset "resultBody" (← getSpec primary #["resultBody", "basic"]) fun entry => do
      let ctx ← entryCtx entry opts config
      SdkUtility.resultBody ctx
      pure ((← SdkUtility.gp ctx "result"), none)

    runset "resultHeaders" (← getSpec primary #["resultHeaders", "basic"]) fun entry => do
      let ctx ← entryCtx entry opts config
      SdkUtility.resultHeaders ctx
      pure ((← SdkUtility.gp ctx "result"), none)

    runset "transformRequest" (← getSpec primary #["transformRequest", "basic"]) fun entry => do
      pure ((← SdkUtility.transformRequest (← entryCtx entry opts config)), none)

    runset "transformResponse" (← getSpec primary #["transformResponse", "basic"]) fun entry => do
      pure ((← SdkUtility.transformResponse (← entryCtx entry opts config)), none)

    -- The remaining corpus sections. They carry no cases in this project's
    -- corpus, but are driven here so any future fixture runs against Lean too.

    -- clean takes (ctx, val), so the fixture supplies `args`, not `in` —
    -- same shape as param/makeError above.
    runset "clean" (← getSpec primary #["clean", "basic"]) fun entry => do
      let args ← SdkUtility.gp entry "args"
      let ctx ← mapCtx entry (← argAt args 0) opts config
      pure ((← SdkUtility.clean ctx (← argAt args 1)), none)

    runset "makeResult" (← getSpec primary #["makeResult", "basic"]) fun entry => do
      pure ((← SdkUtility.makeResult (← entryCtx entry opts config)), none)

    -- makePoint is NOT driven here, and this is deliberate.
    --
    -- The section used to be empty, so running it asserted nothing. It now
    -- carries seven cases, and every one supplies its own `options` (for
    -- allow.op) and `config` (for the operation's points) — but `entryCtx`
    -- OVERWRITES both with the SDK's, so the cases would not run as authored.
    -- Wiring it up needs entryCtx to prefer a fixture-supplied options/config,
    -- which changes every section here and could not be compiled or run when
    -- this change was made.
    --
    -- Left out rather than left in: an entry that runs with the wrong context
    -- is worse than one that does not run, and no coverage is lost — this
    -- section asserted nothing before either.

    runset "makeFetchDef" (← getSpec primary #["makeFetchDef", "basic"]) fun entry => do
      pure ((← SdkUtility.makeFetchDef (← entryCtx entry opts config)), none)

    runset "fetcher" (← getSpec primary #["fetcher", "basic"]) fun entry => do
      let ctx ← entryCtx entry opts config
      let url ← SdkUtility.gpS entry "url"
      pure ((← SdkUtility.fetcher ctx url (← SdkUtility.gp entry "fetchdef")), none)

    runset "featureAdd" (← getSpec primary #["featureAdd", "basic"]) fun entry => do
      let client ← emptyMap
      SdkUtility.featureAdd client (← SdkUtility.gp entry "in")
      pure ((← SdkUtility.gp client "features"), none)

    runset "featureInit" (← getSpec primary #["featureInit", "basic"]) fun entry => do
      let client ← emptyMap
      SdkUtility.featureInit client (← entryCtx entry opts config)
      pure ((← SdkUtility.gp client "features"), none)

    runset "featureHook" (← getSpec primary #["featureHook", "basic"]) fun entry => do
      let client ← emptyMap
      SdkUtility.featureHook client (← SdkUtility.gpS entry "stage") (← entryCtx entry opts config)
      pure ((← SdkUtility.gp client "features"), none)

  go.run sctx
  for f in (← failures.get) do
    IO.println ("FAIL - " ++ f)
  let p ← npass.get
  let f ← nfail.get
  IO.println ""
  IO.println s!"primary-utility: PASS {p}  FAIL {f}"
  if f > 0 then return 1 else return 0
