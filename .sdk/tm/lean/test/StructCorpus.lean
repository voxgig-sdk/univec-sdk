/- Struct corpus: drives the `struct` subtree of the shared
   ../.sdk/test/test.json — the project's own compiled corpus, the same file
   every other target reads — through the vendored voxgig/struct port, on the
   vendored @voxgig/omni engine.

   The ENGINE is no longer in this file. It used to be: an in-tree JSON
   reader, `fixJson`, `eqv`, `matchval`, `doMatch`, `resolveArgs`,
   `checkResult`, `handleError` and `runSet` — this port's own copy of omni's
   algorithm, drifting from it by construction. All of it is gone; every
   group below is handed to omni through OmniResolver. What remains is what
   actually belongs to this SDK: WHICH corpus group drives WHICH struct
   function, and with which flags.

   The file keeps its name (and the `structcorpus` executable keeps its
   root), so no call site — Makefile, lakefile, CI — needed churn.

   Flags mirror canonical: typescript/test/utility/StructUtility.test.ts. -/

import VoxgigStruct
import Omni
import OmniResolver

open VoxgigStruct
open OmniResolver

-- ---------------- subjects that need more than one expression ----------

def nullModifier : ModifyFn := fun v key parent _inj => do
  if v == .str nullmark then
    let _ ← setprop parent key .null
  else match v with
    | .str s =>
      let _ ← setprop parent key (.str (s.replace nullmark "null"))
    | _ => pure ()

/-- walk/log is authored as one {in, out} pair whose `out.after` is the log of
an after-walk. The subject builds that log and returns it; the resolver's
`single (out := ["after"])` selects the half the corpus asserts on. -/
def walkLogSubject (vin : Value) : SIO Value := do
  let log ← emptyList
  let walklog : WalkFn := fun key v parent path => do
    let ks ← if isNullish key then stringify .noval else stringify key
    let vs ← stringify v
    let ps ← if isNullish parent then stringify .noval else stringify parent
    let ts ← pathify path
    let n ← size log
    let _ ← setprop log (vInt n)
      (.str ("k=" ++ ks ++ ", v=" ++ vs ++ ", p=" ++ ps ++ ", t=" ++ ts))
    pure v
  let _ ← walk vin (after := some walklog)
  pure log

def walkCopySubject (vin : Value) : SIO Value := do
  let cur ← IO.mkRef (← newList #[.noval])
  let walkcopy : WalkFn := fun key v _parent path => do
    if isNullish key then do
      let seed ← if ismap v then emptyMap else if islist v then emptyList else pure v
      cur.set (← newList #[seed])
      pure v
    else do
      let i ← size path
      let iN := i.toNat
      let nv ← if isnode v then do
          match (← cur.get) with
          | .list r => do
            let mut xs ← listItems r
            while xs.size <= iN do
              xs := xs.push .noval
            let n ← if ismap v then emptyMap else emptyList
            xs := xs.set! iN n
            setListItems r xs
            pure n
          | _ => pure v
        else pure v
      let tgt ← getelem (← cur.get) (vInt (i - 1))
      let _ ← setprop tgt key nv
      pure v
  let _ ← walk vin (before := some walkcopy)
  getelem (← cur.get) (.num 0.0)

def walkDepthSubject (vin : Value) : SIO Value := do
  let top ← IO.mkRef Value.noval
  let curr ← IO.mkRef Value.noval
  let copy : WalkFn := fun key v _parent _path => do
    if isNullish key || isnode v then do
      let child ← if islist v then emptyList else emptyMap
      if isNullish key then do
        top.set child
        curr.set child
      else do
        let _ ← setprop (← curr.get) key child
        curr.set child
    else
      let _ ← setprop (← curr.get) key v
    pure v
  let _ ← walk (← getp vin "src") (before := some copy) (maxdepth := ← getp vin "maxdepth")
  top.get

-- ---------------- test groups ------------------------------------------

def runAll (r : Run) : SIO Unit := do

  -- minor
  runset r "minor.isnode" (getset r ["minor", "isnode"])
    (fun v => pure (.bool (isnode v)))
  runset r "minor.ismap" (getset r ["minor", "ismap"])
    (fun v => pure (.bool (ismap v)))
  runset r "minor.islist" (getset r ["minor", "islist"])
    (fun v => pure (.bool (islist v)))
  runset r "minor.iskey" (getset r ["minor", "iskey"])
    (fun v => pure (.bool (iskey v))) (nullflag := false)
  runset r "minor.strkey" (getset r ["minor", "strkey"])
    (fun v => pure (.str (strkey v))) (nullflag := false)
  runset r "minor.isempty" (getset r ["minor", "isempty"])
    (fun v => do pure (.bool (← isempty v))) (nullflag := false)
  runset r "minor.isfunc" (getset r ["minor", "isfunc"])
    (fun v => pure (.bool (isfunc v)))
  runset r "minor.clone" (getset r ["minor", "clone"]) clone (nullflag := false)
  runset r "minor.escre" (getset r ["minor", "escre"]) escre
  runset r "minor.escurl" (getset r ["minor", "escurl"]) escurl
  runset r "minor.stringify" (getset r ["minor", "stringify"])
    (fun vin => do
      if ← hasp vin "val" then
        pure (.str (← stringify (← getp vin "val") (maxlen := ← getp vin "max")))
      else
        pure (.str (← stringify .noval)))
    (nullflag := false)
  runset r "minor.jsonify" (getset r ["minor", "jsonify"])
    (fun vin => do
      pure (.str (← jsonify (← getp vin "val") (flags := ← getp vin "flags"))))
    (nullflag := false)
  -- `alt` is read by NULLISHNESS here and by PRESENCE for getprop below.
  -- That is canonical's own split: it omits getprop's alt only when the KEY
  -- is missing (`undefined === vin.alt`), so a present `alt: null` still
  -- goes through, while getelem's rule is the looser `null == vin.alt`.
  -- `minor/getprop#50` and `#51` are the entries that separate them — and
  -- the retired hand-written engine hid the difference, because its `eqv`
  -- matched a no-value against a null. The vendored engine does not.
  runset r "minor.getelem" (getset r ["minor", "getelem"])
    (fun vin => do
      let alt ← getp vin "alt"
      if isNullish alt then getelem (← getp vin "val") (← getp vin "key")
      else getelem (← getp vin "val") (← getp vin "key") alt)
    (nullflag := false)
  runset r "minor.delprop" (getset r ["minor", "delprop"])
    (fun vin => do delprop (← getp vin "parent") (← getp vin "key"))
  runset r "minor.size" (getset r ["minor", "size"])
    (fun v => do pure (vInt (← size v))) (nullflag := false)
  runset r "minor.slice" (getset r ["minor", "slice"])
    (fun vin => do
      slice (← getp vin "val") (start := ← getp vin "start") (stop := ← getp vin "end"))
    (nullflag := false)
  runset r "minor.pad" (getset r ["minor", "pad"])
    (fun vin => do
      pure (.str (← pad (← getp vin "val") (padding := ← getp vin "pad")
        (padchar := ← getp vin "char"))))
    (nullflag := false)
  runset r "minor.pathify" (getset r ["minor", "pathify"])
    (fun vin => do
      if ← hasp vin "path" then
        pure (.str (← pathify (← getp vin "path") (startin := ← getp vin "from")))
      else
        pure (.str (← pathify .noval (startin := ← getp vin "from") (absent := true))))
    (nullflag := false)
  runset r "minor.items" (getset r ["minor", "items"]) items
  runset r "minor.getprop" (getset r ["minor", "getprop"])
    (fun vin => do
      if ← hasp vin "alt" then
        getprop (← getp vin "val") (← getp vin "key") (← getp vin "alt")
      else getprop (← getp vin "val") (← getp vin "key"))
    (nullflag := false)
  runset r "minor.setprop" (getset r ["minor", "setprop"])
    (fun vin => do
      setprop (← getp vin "parent") (← getp vin "key") (← getp vin "val"))
  runset r "minor.haskey" (getset r ["minor", "haskey"])
    (fun vin => do
      pure (.bool (← haskey (← getp vin "src") (← getp vin "key"))))
    (nullflag := false)
  runset r "minor.keysof" (getset r ["minor", "keysof"])
    (fun v => do newList ((← keysof v).map (fun s => Value.str s)))
  runset r "minor.join" (getset r ["minor", "join"])
    (fun vin => do
      let url := (← getp vin "url") == .bool true
      pure (.str (← join (← getp vin "val") (sep := ← getp vin "sep") (url := url))))
    (nullflag := false)
  runset r "minor.typify" (getset r ["minor", "typify"])
    (fun v => pure (vInt (typify v))) (nullflag := false)
  runset r "minor.setpath" (getset r ["minor", "setpath"])
    (fun vin => do
      setpath (← getp vin "store") (← getp vin "path") (← getp vin "val"))
    (nullflag := false)
  runset r "minor.filter" (getset r ["minor", "filter"])
    (fun vin => do
      let checkV ← getp vin "check"
      let check : (String × Value) → Bool :=
        if checkV == .str "gt3" then
          fun (_, x) => match x with | .num n => n > 3.0 | _ => false
        else if checkV == .str "lt3" then
          fun (_, x) => match x with | .num n => n < 3.0 | _ => false
        else fun _ => false
      filter (← getp vin "val") check)
  runset r "minor.typename" (getset r ["minor", "typename"])
    (fun v => do
      let t : Int := match v with
        | .num n => fToInt n
        | _ => 0
      pure (.str (typename t)))
  runset r "minor.flatten" (getset r ["minor", "flatten"])
    (fun vin => do
      match (← getp vin "depth") with
      | .num n => flatten (← getp vin "val") (depth := fToInt n)
      | _ => flatten (← getp vin "val"))

  -- walk
  runset r "walk.log" (single (getset r ["walk", "log"]) (out := ["after"]))
    walkLogSubject
  runset r "walk.basic" (getset r ["walk", "basic"])
    (fun vin => do
      walk vin (after := some (fun _k v _p path => do
        match v with
        | .str s => do
          let mut parts : List String := []
          for x in (← listItemsOf path) do
            parts := (← jsString x) :: parts
          pure (.str (s ++ "~" ++ String.intercalate "." parts.reverse))
        | _ => pure v)))
  runset r "walk.copy" (getset r ["walk", "copy"]) walkCopySubject
  runset r "walk.depth" (getset r ["walk", "depth"]) walkDepthSubject
    (nullflag := false)

  -- merge
  runset r "merge.basic" (single (getset r ["merge", "basic"]))
    (fun vin => do merge (← clone vin))
  runset r "merge.cases" (getset r ["merge", "cases"]) (fun v => merge v)
  runset r "merge.array" (getset r ["merge", "array"]) (fun v => merge v)
  runset r "merge.integrity" (getset r ["merge", "integrity"]) (fun v => merge v)
  runset r "merge.depth" (getset r ["merge", "depth"])
    (fun vin => do merge (← getp vin "val") (maxdepth := ← getp vin "depth"))

  -- getpath
  runset r "getpath.basic" (getset r ["getpath", "basic"])
    (fun vin => do getpath (← getp vin "store") (← getp vin "path"))
  runset r "getpath.relative" (getset r ["getpath", "relative"])
    (fun vin => do
      let dpath ← match (← getp vin "dpath") with
        | .str s => newList ((s.splitOn ".").map (fun x => Value.str x)).toArray
        | _ => pure Value.noval
      let d : InjDef := { dDparent := ← getp vin "dparent", dDpath := dpath }
      getpath (← getp vin "store") (← getp vin "path") (.idef d))
  runset r "getpath.special" (getset r ["getpath", "special"])
    (fun vin => do
      let injm ← getp vin "inj"
      let d : InjDef := {
        dBase := ← getprop injm (.str "base"), dMeta := ← getprop injm (.str "meta"),
        dDparent := ← getprop injm (.str "dparent"), dDpath := ← getprop injm (.str "dpath"),
        dKey := ← getprop injm (.str "key") }
      getpath (← getp vin "store") (← getp vin "path")
        (if isNullish injm then .inone else .idef d))
  runset r "getpath.handler" (getset r ["getpath", "handler"])
    (fun vin => do
      let foo ← vFunc (fun _ _ _ _ => pure (.str "foo"))
      let store ← omapV [("$TOP", ← getp vin "store"), ("$FOO", foo)]
      let h ← registerFunc (fun _inj v _ref _store => do
        match v with
        | .func fid => callFunc fid (← getDummyInj) .noval "" .noval
        | _ => pure v)
      let d : InjDef := { dHandler := some h }
      getpath store (← getp vin "path") (.idef d))

  -- inject
  runset r "inject.basic" (single (getset r ["inject", "basic"]))
    (fun vin => do
      inject (← clone (← getp vin "val")) (← clone (← getp vin "store")))
  runset r "inject.string" (getset r ["inject", "string"])
    (fun vin => do
      let mid ← registerModify nullModifier
      let d : InjDef := { dModify := some mid, dExtra := ← getp vin "current" }
      inject (← getp vin "val") (← getp vin "store") (.idef d))
  runset r "inject.deep" (getset r ["inject", "deep"])
    (fun vin => do inject (← getp vin "val") (← getp vin "store"))

  -- transform
  runset r "transform.basic" (single (getset r ["transform", "basic"]))
    (fun vin => do transform (← getp vin "data") (← getp vin "spec"))
  for gn in ["paths", "cmds", "each", "pack", "ref"] do
    runset r ("transform." ++ gn) (getset r ["transform", gn])
      (fun vin => do transform (← getp vin "data") (← getp vin "spec"))
  runset r "transform.modify" (getset r ["transform", "modify"])
    (fun vin => do
      let mid ← registerModify (fun v key parent _inj => do
        match v with
        | .str s =>
          if !(isNullish key) && !(isNullish parent) then
            let _ ← setprop parent key (.str ("@" ++ s))
        | _ => pure ())
      let d : InjDef := { dModify := some mid, dExtra := ← getp vin "store" }
      transform (← getp vin "data") (← getp vin "spec") (.idef d))
  runset r "transform.format" (getset r ["transform", "format"])
    (fun vin => do transform (← getp vin "data") (← getp vin "spec"))
    (nullflag := false)
  runset r "transform.apply" (getset r ["transform", "apply"])
    (fun vin => do transform (← getp vin "data") (← getp vin "spec"))

  -- validate
  runset r "validate.basic" (getset r ["validate", "basic"])
    (fun vin => do validate (← getp vin "data") (← getp vin "spec"))
    (nullflag := false)
  for gn in ["child", "one", "exact"] do
    runset r ("validate." ++ gn) (getset r ["validate", gn])
      (fun vin => do validate (← getp vin "data") (← getp vin "spec"))
  runset r "validate.invalid" (getset r ["validate", "invalid"])
    (fun vin => do validate (← getp vin "data") (← getp vin "spec"))
    (nullflag := false)
  runset r "validate.special" (getset r ["validate", "special"])
    (fun vin => do
      let injm ← getp vin "inj"
      let d : InjDef := { dMeta := ← getprop injm (.str "meta") }
      validate (← getp vin "data") (← getp vin "spec")
        (if isNullish injm then .inone else .idef d))

  -- select
  for gn in ["basic", "operators", "edge", "alts"] do
    runset r ("select." ++ gn) (getset r ["select", gn])
      (fun vin => do select (← getp vin "obj") (← getp vin "query"))

  -- nullsem: does a PRESENT key holding a JSON null read as "no value"?
  -- Every group runs {null: false} — the whole point of the section is the
  -- distinction the null flag would erase.
  --
  -- This section used to be looked up as `sentinels`, under six group names
  -- (`getprop_unify`, `getelem_absent`, `haskey_unify`, `isempty_unify`,
  -- `isnode_unify`, `stringify_null`) the shipped corpus has never carried —
  -- alongside a `regex` section it has never carried either. All eleven
  -- groups therefore ran ZERO cases, silently. The vendored engine names a
  -- missing group out loud (`SKIP`), which is how that was found; the
  -- regex groups are gone because this port's `reTest`/`reFind`/... have no
  -- corpus to answer, and nullsem is driven under the name it actually has.
  runset r "nullsem.getprop" (getset r ["nullsem", "getprop"])
    (fun vin => do
      if ← hasp vin "alt" then
        getprop (← getp vin "val") (← getp vin "key") (← getp vin "alt")
      else getprop (← getp vin "val") (← getp vin "key"))
    (nullflag := false)
  runset r "nullsem.getelem" (getset r ["nullsem", "getelem"])
    (fun vin => do
      if ← hasp vin "alt" then
        getelem (← getp vin "val") (← getp vin "key") (← getp vin "alt")
      else getelem (← getp vin "val") (← getp vin "key"))
    (nullflag := false)
  runset r "nullsem.getpath" (getset r ["nullsem", "getpath"])
    (fun vin => do getpath (← getp vin "store") (← getp vin "path"))
    (nullflag := false)
  runset r "nullsem.haskey" (getset r ["nullsem", "haskey"])
    (fun vin => do
      pure (.bool (← haskey (← getp vin "src") (← getp vin "key"))))
    (nullflag := false)
  runset r "nullsem.keysof" (getset r ["nullsem", "keysof"])
    (fun v => do newList ((← keysof v).map (fun s => Value.str s)))
    (nullflag := false)

-- ---------------- main --------------------------------------------------

def main (argv : List String) : IO UInt32 := do
  let testfile ← resolveSpecPath argv
  let r ← makeRun testfile "struct"
  let sctx ← mkCtx
  (runAll r).run sctx
  report r "STRUCT CORPUS: "
