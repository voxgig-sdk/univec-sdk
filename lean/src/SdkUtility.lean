/- Univec SDK request-shaping utilities (the primary utility layer).

   These are the language-neutral pipeline utilities the shared test corpus
   (.sdk/test/test.json, section `primary`) exercises in every target. The
   context is a struct `Value` map: heap-backed and reference-stable, so the
   utilities mutate it in place exactly as the IORef/pointer-based donors do,
   and nested `ctx.spec` / `ctx.result` handles stay live across calls. -/

import VoxgigStruct
import SdkJson

open VoxgigStruct

namespace SdkUtility

-- ---------------------------------------------------------------------------
-- Value helpers
-- ---------------------------------------------------------------------------

def gp (v : Value) (k : String) : SIO Value := getprop v (.str k) .noval

def sp (v : Value) (k : String) (x : Value) : SIO Unit := do
  let _ ← setprop v (.str k) x

def dp (v : Value) (k : String) : SIO Unit := do
  let _ ← delprop v (.str k)

def vs : Value → String
  | .str s => s
  | _ => ""

def isNov : Value → Bool
  | .noval => true
  | _ => false

def isMapV : Value → Bool
  | .map _ => true
  | _ => false

def truthy : Value → Bool
  | .bool b => b
  | _ => false

def gpS (v : Value) (k : String) : SIO String := do pure (vs (← gp v k))

/-- Field as a map, creating AND attaching an empty map when absent. -/
def gpMap (v : Value) (k : String) : SIO Value := do
  match (← gp v k) with
  | .map i => pure (.map i)
  | _ => do
    let m ← emptyMap
    sp v k m
    pure m

/-- A map view of a value (empty map when it is not a map); does not attach. -/
def asMap (v : Value) : SIO Value := do
  match v with
  | .map i => pure (.map i)
  | _ => emptyMap

/-- An SDK error value: a struct map tagged `__sdkerr__`. -/
def mkErr (code msg : String) : SIO Value :=
  newMap #[("__sdkerr__", .bool true), ("code", .str code), ("message", .str msg)]

def isErrV (v : Value) : SIO Bool := do
  match v with
  | .map _ => pure (truthy (← gp v "__sdkerr__"))
  | _ => pure false

-- ---------------------------------------------------------------------------
-- clean: what leaves the pipeline is masked
--
-- Everything that leaves the pipeline passes through `clean`; inside it data
-- stays raw, so a hook can still read the header it must add to. See the
-- generator's docs/explanation/secret-redaction.md.
-- ---------------------------------------------------------------------------

def CLEAN_MAXDEPTH : Nat := 32

/-- The `clean` block of the option spec (main.kit.optspec.clean in the sdkgen
    base model), held here because this pack's targets read no generated
    Schema module. Numbers are strings, like every optspec value. -/
def cleanOptSpec : SIO Value :=
  newMap #[("active", .bool true),
           ("keys", .str "key,secret,token,password,passwd,authorization,cookie,credential,signature"),
           ("values", .str ""), ("mask", .str "[redacted]"), ("hint", .str "0"), ("min", .str "4")]

def normkey (k : String) : String :=
  String.ofList (k.toLower.toList.filter (fun c => c != '-' && c != '_'))

def trimS (s : String) : String := s.trimAscii.toString

def splitkeys (v : Value) : Array String :=
  (((vs v).splitOn ",").toArray.map (fun k => normkey (trimS k))).filter (· != "")

def splitvalues (v : Value) : SIO (Array String) := do
  match v with
  | .list id => pure ((← listItems id).filterMap (fun x => match x with | .str s => some s | _ => none))
  | .str s => pure (((s.splitOn ",").toArray.map trimS).filter (· != ""))
  | _ => pure #[]

def countOpt (v : Value) (dflt : Nat) : Nat :=
  match v with
  | .num n => if n >= 0.0 then (fToInt n).toNat else dflt
  | .str s => (trimS s).toNat?.getD dflt
  | _ => dflt

/-- The derived clean block is a map, so features can register into its
    `values` list after makeOptions; `keys` holds the normalised names. -/
def makeCleanConfig (cleanopts : Value) : SIO Value := do
  let opts ← asMap cleanopts
  let active := match (← gp opts "active") with | .bool false => false | _ => true
  let keys ← newList ((splitkeys (← gp opts "keys")).map Value.str)
  let values ← emptyList
  let mask := match (← gp opts "mask") with | .str m => m | _ => "[redacted]"
  let hint := countOpt (← gp opts "hint") 0
  let mn := max 1 (countOpt (← gp opts "min") 4)
  newMap #[("active", .bool active), ("keys", keys), ("values", values),
           ("mask", .str mask), ("hint", .num hint.toFloat), ("min", .num mn.toFloat)]

/-- Options without a derived block (a bare context) still mask by the
    schema defaults. -/
def cleanConfigOfOptions (options : Value) : SIO Value := do
  let derived ← gp (← gp options "__derived__") "clean"
  match derived with
  | .map _ => pure derived
  | _ => do makeCleanConfig (← cleanOptSpec)

def cleanConfig (ctx : Value) : SIO Value := do cleanConfigOfOptions (← gp ctx "options")

def cfgStrings (cfg : Value) (k : String) : SIO (Array String) := do
  pure ((← listItemsOf (← gp cfg k)).filterMap (fun x => match x with | .str s => some s | _ => none))

def cfgNat (cfg : Value) (k : String) (d : Nat) : SIO Nat := do
  match (← gp cfg k) with
  | .num n => pure (fToInt n).toNat
  | _ => pure d

def base64Encode (s : String) : String := Id.run do
  let tbl := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray
  let bytes := s.toUTF8
  let enc (n : Nat) : Char := tbl[n % 64]!
  let mut out := ""
  for t in [0 : bytes.size / 3] do
    let i := t * 3
    let n := (bytes[i]!.toNat <<< 16) ||| (bytes[i + 1]!.toNat <<< 8) ||| bytes[i + 2]!.toNat
    out := (((out.push (enc (n >>> 18))).push (enc (n >>> 12))).push (enc (n >>> 6))).push (enc n)
  let i := (bytes.size / 3) * 3
  let rem := bytes.size - i
  if rem == 2 then
    let n := (bytes[i]!.toNat <<< 16) ||| (bytes[i + 1]!.toNat <<< 8)
    out := (((out.push (enc (n >>> 18))).push (enc (n >>> 12))).push (enc (n >>> 6))).push '='
  else if rem == 1 then
    let n := bytes[i]!.toNat <<< 16
    out := (((out.push (enc (n >>> 18))).push (enc (n >>> 12))).push '=').push '='
  return out

def hexDigitVal (c : Char) : Option Nat :=
  if c.isDigit then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

partial def percentDecodeBytes : List Char → ByteArray → Option ByteArray
  | '%' :: a :: b :: rest, acc =>
    match hexDigitVal a, hexDigitVal b with
    | some x, some y => percentDecodeBytes rest (acc.push (x * 16 + y).toUInt8)
    | _, _ => none
  | '%' :: _, _ => none
  | c :: rest, acc => percentDecodeBytes rest (acc ++ c.toString.toUTF8)
  | [], acc => some acc

/-- The decoded form, as decodeURIComponent reads it: the escapes are UTF-8
    octets, and a malformed escape or sequence has no decoded form. -/
def percentDecode (s : String) : Option String :=
  (percentDecodeBytes s.toList ByteArray.empty).bind String.fromUTF8?

/-- The encoded forms a value travels in. -/
def cleanForms (value : String) : SIO (Array String) := do
  let pe ← match (← escurl (.str value)) with | .str s => pure s | _ => pure value
  let js := jsonEscapeStr value
  let jsIn := if js.length >= 2 then ((js.drop 1).dropEnd 1).toString else js
  let mut out : Array String := #[]
  for f in #[value, base64Encode value, pe, jsIn] do
    if f != "" && !out.contains f then out := out.push f
  pure out

def cleanAddCfg (cfg : Value) (value : Value) : SIO Unit := do
  let mn ← cfgNat cfg "min" 4
  match value with
  | .str s =>
    if s.length < mn then return ()
    match (← gp cfg "values") with
    | .list id =>
      let cur := (← listItems id).filterMap (fun x => match x with | .str t => some t | _ => none)
      let mut merged := cur
      let mut changed := false
      for f in (← cleanForms s) do
        if f.length >= mn && !merged.contains f then
          merged := merged.push f
          changed := true
      if changed then
        setListItems id ((merged.qsort (fun a b => a.length > b.length)).map Value.str)
    | _ => pure ()
  | _ => pure ()

def cleanAddOptions (options : Value) (value : Value) : SIO Unit := do
  cleanAddCfg (← cleanConfigOfOptions options) value

def cleanAdd (ctx : Value) (value : Value) : SIO Unit := do cleanAddCfg (← cleanConfig ctx) value

structure CleanRule where
  active : Bool
  mask : String
  hint : Nat
  keys : Array String
  values : Array String

def cleanRule (cfg : Value) : SIO CleanRule := do
  let active := match (← gp cfg "active") with | .bool false => false | _ => true
  let mask := match (← gp cfg "mask") with | .str m => m | _ => "[redacted]"
  pure { active := active, mask := mask, hint := ← cfgNat cfg "hint" 0,
         keys := ← cfgStrings cfg "keys", values := ← cfgStrings cfg "values" }

def maskValue (r : CleanRule) (v : String) : String :=
  if r.hint > 0 && v.length > 2 * r.hint then r.mask ++ v.drop (v.length - r.hint) else r.mask

def cleanStr (r : CleanRule) (text : String) : String := Id.run do
  let mut out := text
  for v in r.values do
    out := out.replace v (maskValue r v)
  return out

def sensitiveKey (keys : Array String) (key : Option String) : Bool :=
  match key with
  | some k => let nk := normkey k; keys.any (fun s => (nk.splitOn s).length > 1)
  | none => false

def cleanKey (ctx : Value) (key : String) : SIO Bool := do
  pure (sensitiveKey (← cfgStrings (← cleanConfig ctx) "keys") (some key))

/-- A registered value used as a property name is masked like any other
    string; names that mask alike take a counter, so none is lost. -/
def cleanName (r : CleanRule) (out : Array (String × Value)) (key : String) : String := Id.run do
  let name := cleanStr r key
  let taken := fun (n : String) => out.any (fun e => e.1 == n)
  if name == key || !taken name then return name
  -- One of out.size + 1 counters is always free.
  for i in [1 : out.size + 2] do
    let n := name ++ "#" ++ toString i
    if !taken n then return n
  return name

/-- A masked plain-data copy: functions dropped, cycles cut, and nothing
    shared with the live value, whose spec must stay raw. -/
partial def snapshot (r : CleanRule) (key : Option String) (depth : Nat) (seen : Array Nat)
    (v : Value) : SIO Value := do
  let sensitive := sensitiveKey r.keys key
  match v with
  | .noval | .null => pure v
  | .str s => pure (.str (if sensitive then maskValue r s else cleanStr r s))
  | .func _ => pure .noval
  | .list id =>
    if depth >= CLEAN_MAXDEPTH || seen.contains id then pure (.str "[circular]")
    else if sensitive then pure (.str r.mask)
    else do
      let mut out : Array Value := #[]
      for x in (← listItems id) do
        out := out.push (← snapshot r none (depth + 1) (seen.push id) x)
      newList out
  | .map id =>
    if depth >= CLEAN_MAXDEPTH || seen.contains id then pure (.str "[circular]")
    else if sensitive then pure (.str r.mask)
    else do
      let mut out : Array (String × Value) := #[]
      for (k, x) in (← mapEntries id) do
        match x with
        | .func _ => pure ()
        | _ =>
          let y ← snapshot r (some k) (depth + 1) (seen.push id) x
          out := out.push (cleanName r out k, y)
      newMap out
  | _ => pure (if sensitive then .str r.mask else v)

/-- Every scalar under a sensitive name, at any depth and of any shape: a
    credential mistyped as a map or a number is still a credential. -/
partial def cleanAddSensitiveCfg (cfg : Value) (v : Value) (under : Bool := false)
    (depth : Nat := 0) (seen : Array Nat := #[]) : SIO Unit := do
  if depth >= CLEAN_MAXDEPTH then return ()
  match v with
  | .str _ => if under then cleanAddCfg cfg v
  | .num n => if under then cleanAddCfg cfg (.str (numToString n))
  | .list id =>
    if !seen.contains id then
      for x in (← listItems id) do
        cleanAddSensitiveCfg cfg x under (depth + 1) (seen.push id)
  | .map id =>
    if !seen.contains id then
      let keys ← cfgStrings cfg "keys"
      for (k, x) in (← mapEntries id) do
        cleanAddSensitiveCfg cfg x (under || sensitiveKey keys (some k)) (depth + 1) (seen.push id)
  | _ => pure ()

def cleanAddSensitive (ctx : Value) (v : Value) : SIO Unit := do
  cleanAddSensitiveCfg (← cleanConfig ctx) v

/-- A shallow copy of a map without the named keys; the values are shared. -/
def withoutKeys (v : Value) (ks : Array String) : SIO Value := do
  match v with
  | .map id => newMap ((← mapEntries id).filter (fun e => !ks.contains e.1))
  | _ => pure v

/-- The keys directly under `feature` name features, not fields: `secrets`
    is a feature, and its settings are not secrets for sitting under it.
    Entity blocks hold per-entity settings and seeded records, never a
    credential. -/
def cleanAddSensitiveOptions (cfg options : Value) (skip : Array String) : SIO Unit := do
  let rest ← withoutKeys options (skip ++ #["feature", "entity"])
  let test ← gp options "test"
  if isMapV rest && isMapV test then sp rest "test" (← withoutKeys test #["entity"])
  cleanAddSensitiveCfg cfg rest
  match (← gp options "feature") with
  | .map id => for (_, fopts) in (← mapEntries id) do
      cleanAddSensitiveCfg cfg (← withoutKeys fopts #["entity"])
  | .list id => for fopts in (← listItems id) do
      cleanAddSensitiveCfg cfg (← withoutKeys fopts #["entity"])
  | feature => cleanAddSensitiveCfg cfg feature

def cleanWithCfg (cfg : Value) (v : Value) : SIO Value := do
  let r ← cleanRule cfg
  if r.active then snapshot r none 0 #[] v else pure v

/-- Mask what is about to leave: a string has every registered value form
    replaced; a structure comes back as a masked copy. `active: false`
    returns the value untouched. -/
def clean (ctx : Value) (v : Value) : SIO Value := do cleanWithCfg (← cleanConfig ctx) v

/-- The serialised context leaves the pipeline (a hook's dump, a log line),
    so it is cleaned; the live fields stay raw for the pipeline's own use. -/
def contextJson (ctx : Value) : SIO Value := do
  let record ← newMap #[("op", ← gp ctx "op"), ("spec", ← gp ctx "spec"),
                        ("result", ← gp ctx "result"), ("response", ← gp ctx "response"),
                        ("point", ← gp ctx "point")]
  clean ctx record

-- ---------------------------------------------------------------------------
-- Operation naming
-- ---------------------------------------------------------------------------

/-- The op-name convention, used only when the API definition names no
    method for the point.

    NO CATCH-ALL GET. The ts reference returns `methodMap[key]`, which is
    undefined for an op the map does not name — the request is then rejected
    rather than silently issued. A `| _ => "GET"` here turned every
    unrecognised op into a GET, which is both a divergence from the corpus
    (`primary/prepareMethod` case 6, opname "bad", expects no method) and the
    more dangerous of the two behaviours: a mistyped or unsupported op quietly
    fetched. "" is Lean's spelling of the same "no value"; the seven other
    targets that carried this bug answer it identically. -/
def opMethodOf : String → String
  | "create" => "POST"
  | "update" => "PUT"
  | "load"   => "GET"
  | "list"   => "GET"
  | "remove" => "DELETE"
  | "patch"  => "PATCH"
  | _        => ""

def opInputOf : String → String
  | "create" => "data"
  | "update" => "data"
  | "patch"  => "data"
  | _        => "match"

/-- The operation name: `ctx.opname`, falling back to `ctx.op.name`. -/
def opnameOf (ctx : Value) : SIO String := do
  let n ← gpS ctx "opname"
  if n != "" then pure n
  else do gpS (← gp ctx "op") "name"

-- ---------------------------------------------------------------------------
-- makeOptions / makeContext / operator / makeError / done
-- ---------------------------------------------------------------------------

def allowDefaults : SIO Value :=
  newMap #[("op", .str "create,update,patch,load,list,remove,command,direct,graphql"),
           ("method", .str "GET,PUT,POST,PATCH,DELETE,OPTIONS")]

def defaultOptions : SIO Value := do
  let hdr ← newMap #[("content-type", .str "application/json")]
  let ent ← emptyMap
  -- `allow.op` and `allow.method` carry the ts optspec's own defaults,
  -- because makePoint and makeSpec enforce them; the other optspec slots are
  -- not defaulted here, so nothing below is a value a caller could mistake
  -- for an enforced one.
  newMap #[("base", .str "http://localhost:8000"), ("prefix", .str ""),
           ("suffix", .str ""), ("headers", hdr), ("entity", ent),
           ("allow", ← allowDefaults), ("clean", ← cleanOptSpec)]

/-- A nullish or missing `allow`, `allow.op` or `allow.method` takes the default,
    as validate fills it in the other targets: the raw gate in `allowRefuses`
    would refuse a null and let an undefined one allow everything. -/
def fillAllowDefaults (opts : Value) : SIO Unit := do
  let defaults ← allowDefaults
  let allow ← lookupRaw opts (.str "allow")
  if isNullish allow then sp opts "allow" defaults
  else if isMapV allow then
    for k in (← keysof defaults) do
      if isNullish (← lookupRaw allow (.str k)) then sp allow k (← gp defaults k)

/-- Defaults <- config.options <- options, then a nullish or missing allow list
    takes its default and every entity gets an alias map. Neither the caller's
    options nor the model's are changed. -/
def makeOptions (config options : Value) : SIO Value := do
  let base ← defaultOptions
  -- Copies: merge writes each merged child back into the map it walks.
  let copts ← clone (← asMap (← gp config "options"))
  let uopts ← clone (← asMap options)
  -- The secret registry is fed from the RAW input, before anything else
  -- reads the options.
  let cfgclean ← gp copts "clean"
  let cfgcleanM ← match cfgclean with | .map _ => clone cfgclean | _ => emptyMap
  let rawclean ← gp uopts "clean"
  let rawcleanM ← match rawclean with | .map _ => clone rawclean | _ => emptyMap
  let cleanmerged ← merge (← newList #[← emptyMap, ← cleanOptSpec, cfgcleanM, rawcleanM])
  let cleancfg ← makeCleanConfig cleanmerged
  cleanAddSensitiveOptions cleancfg uopts #["clean"]
  for v in (← splitvalues (← gp cfgclean "values")) ++ (← splitvalues (← gp rawclean "values")) do
    cleanAddCfg cleancfg (.str v)
  let parts ← newList #[base, copts, uopts]
  let out ← merge parts
  fillAllowDefaults out
  let ent ← gpMap out "entity"
  for k in (← keysof ent) do
    let e ← gp ent k
    match e with
    | .map _ =>
      match (← gp e "alias") with
      | .map _ => pure ()
      | _ => do
        let a ← emptyMap
        sp e "alias" a
    | _ => pure ()
  sp out "__derived__" (← newMap #[("clean", cleancfg)])
  -- Again over the merged result: the config's own defaults can carry one.
  cleanAddSensitiveOptions cleancfg out #["clean", "__derived__"]
  pure out

def makeContext (ctxmap : Value) : SIO Value := do
  let ctx ← if isMapV ctxmap then pure ctxmap else emptyMap
  let opname ← opnameOf ctx
  let op ← gpMap ctx "op"
  if (← gpS op "name") == "" then sp op "name" (.str opname)
  if (← gpS op "input") == "" then sp op "input" (.str (opInputOf opname))
  pure ctx

/-- The Operation record (entity/name/input/points) as a plain map. -/
def operator (inv : Value) : SIO Value := do
  let ent ← gp inv "entity"
  let nm ← gp inv "name"
  let inp ← gp inv "input"
  let pts ← match (← gp inv "points") with
    | .list i => pure (Value.list i)
    | _ => emptyList
  newMap #[("entity", ent), ("name", nm), ("input", inp), ("points", pts)]

def sdkNameOf (ctx : Value) : SIO String := do
  let cfg ← gp ctx "config"
  gpS (← gp cfg "main") "name"

/-- "<Name>SDK: <opname>: <message>", with the neutral fallbacks. -/
def makeError (ctx : Value) (errv : Value) : SIO Value := do
  let nm ← sdkNameOf ctx
  let opn ← opnameOf ctx
  let opname := if opn == "" then "unknown operation" else opn
  let m1 ← match errv with
    | .map _ => gpS errv "message"
    | _ => pure ""
  let rerr ← gp (← gp ctx "result") "err"
  let m2 ← match rerr with
    | .map _ => gpS rerr "message"
    | _ => pure ""
  let msg := if m1 != "" then m1 else if m2 != "" then m2 else "unknown error"
  -- About to be thrown: the message is cleaned as it is built.
  let full ← clean ctx (.str (nm ++ "SDK: " ++ opname ++ ": " ++ msg))
  mkErr "sdk_error" (vs full)

/-- The explain record the caller asked for, finished off: sensitive keys
    removed, and the result's error dropped from it. The error is reported on
    its own, so leaving a copy inside the explained result means a caller
    reading the record cannot tell a failure it already handled from a fresh
    one. Mirrors ts's DoneUtility. -/
def doneExplain (ctx : Value) : SIO Unit := do
  let ctrl ← gp ctx "ctrl"
  match (← gp ctrl "explain") with
  | .map id => do
    let r ← cleanRule (← cleanConfig ctx)
    -- A copy even with clean off, masking nothing: the result pruned below
    -- is otherwise the live one, whose error failOp has still to read.
    let copy ← snapshot (if r.active then r else { r with keys := #[], values := #[] })
      none 0 #[] (.map id)
    -- Written back in place: the caller may hold the record it passed.
    setMapEntries id (← mapEntriesOf copy)
    let res ← gp (.map id) "result"
    if isMapV res then dp res "err"
  | _ => pure ()

/-- Terminal step: the result payload, or the pipeline error. -/
def done (ctx : Value) : SIO (Value × Option Value) := do
  doneExplain ctx
  let res ← gp ctx "result"
  if truthy (← gp res "ok") then pure ((← gp res "resdata"), none)
  else do
    let e ← makeError ctx .noval
    pure (.noval, some e)

-- ---------------------------------------------------------------------------
-- param / prepare*
-- ---------------------------------------------------------------------------

/-- Resolve a parameter by name across reqmatch/match/reqdata/data, honouring
    the point's alias map (and recording the reverse alias on the spec). -/
def param (ctx : Value) (paramdef : Value) : SIO Value := do
  let point ← gp ctx "point"
  let specV ← gp ctx "spec"
  let mtch ← gp ctx "match"
  let reqmatch ← gp ctx "reqmatch"
  let dat ← gp ctx "data"
  let reqdata ← gp ctx "reqdata"
  let key ← match paramdef with
    | .str s => pure s
    | _ => gpS paramdef "name"
  let aliasV ← gp point "alias"
  let akey ← match aliasV with
    | .map _ => gpS aliasV key
    | _ => pure ""
  let v1 ← gp reqmatch key
  let v2 ← if isNov v1 then gp mtch key else pure v1
  let v3 ← if isNov v2 && akey != "" then do
      match specV with
      | .map _ => do
        let sa ← gpMap specV "alias"
        sp sa akey (.str key)
      | _ => pure ()
      gp reqmatch akey
    else pure v2
  let v4 ← if isNov v3 then gp reqdata key else pure v3
  let v5 ← if isNov v4 then gp dat key else pure v4
  if isNov v5 && akey != "" then do
    let a ← gp reqdata akey
    if isNov a then gp dat akey else pure a
  else pure v5

/-- Path params declared by the point's args, resolved through `param`. -/
def prepareParams (ctx : Value) : SIO Value := do
  let point ← gp ctx "point"
  let args ← gp point "args"
  let out ← emptyMap
  match (← gp args "params") with
  | .list i =>
    for pd in (← listItems i) do
      let v ← param ctx pd
      if !(isNov v) then do
        let nm ← match pd with
          | .str s => pure s
          | _ => gpS pd "name"
        if nm != "" then sp out nm v
  | _ => pure ()
  pure out

def argDefs (point : Value) (kind : String) : SIO (Array Value) := do
  match (← gp (← gp point "args") kind) with
  | .list i => listItems i
  | _ => pure #[]

/-- A declared header, cookie or query argument of the point: the name it
    travels under, and the value the call passes in its match or data. -/
def callArgs (ctx : Value) (kind : String) : SIO (Array (String × String × Value)) := do
  let point ← gp ctx "point"
  let reqmatch ← gp ctx "reqmatch"
  let reqdata ← gp ctx "reqdata"
  let mut out : Array (String × String × Value) := #[]
  for ad in (← argDefs point kind) do
    let name ← gpS ad "name"
    if name != "" then
      let orig ← gpS ad "orig"
      let mv ← gp reqmatch name
      let val ← if isNov mv then gp reqdata name else pure mv
      out := out.push (name, (if orig == "" then name else orig), val)
  pure out

/-- Everything in reqmatch that is NOT a path, header or cookie argument becomes
    query, under its wire name, with the query arguments the call passes. -/
def prepareQuery (ctx : Value) : SIO Value := do
  let point ← gp ctx "point"
  let reqmatch ← asMap (← gp ctx "reqmatch")
  let argNames (kind : String) : SIO (Array String) := do
    (← argDefs point kind).mapM (fun d => gpS d "name")

  -- A path parameter travels in the path. The generated config lists them as
  -- args.params, which prepareParams reads; params is the older list of names.
  let params ← match (← gp point "params") with
    | .list i => do pure ((← listItems i).map vs)
    | _ => pure #[]
  let inpath := params ++ (← argNames "params")

  -- A query parameter travels under the name the definition gives it, its
  -- orig, which the model may have renamed for the caller.
  let wires ← (← argDefs point "query").mapM (fun d => do
    pure ((← gpS d "name"), (← gpS d "orig")))
  let declared := (wires.map (·.1)).filter (· != "")
  let wireOf (k : String) : String :=
    match wires.find? (fun (n, o) => n == k && o != "") with
    | some (_, o) => o
    | none => k

  -- A header or cookie parameter travels in the headers, which prepareHeaders
  -- fills, unless a query parameter shares its name: then both are sent.
  let elsewhere := ((← argNames "header") ++ (← argNames "cookie")).filter
    (fun n => !(declared.contains n))

  let out ← emptyMap
  for k in (← keysof reqmatch) do
    let v ← gp reqmatch k
    if !(isNov v) && k != "$action" && !(inpath.contains k) && !(elsewhere.contains k) then
      sp out (wireOf k) v

  -- A create or update passes its query arguments in its data.
  for (name, wire, val) in (← callArgs ctx "query") do
    if !(isNov val) && !(inpath.contains name) then sp out wire val
  pure out

/-- Assemble the path template from `point.parts`. This is `struct.join` with
the url flag — NOT a plain intercalate: empty segments are dropped (a doubled
slash changes the URL and 404s on strict routers) and there is no leading
slash, because makeUrl joins base/prefix/path/suffix with `joinurl`. -/
def preparePath (ctx : Value) : SIO String := do
  let point ← gp ctx "point"
  join (← gp point "parts") (sep := .str "/") (url := true)

/-- The API definition is authoritative: a POST-only or PATCH-based API
exposes `update` as POST or PATCH, not the PUT the op name implies. Only
fall back to the op-name convention when the point has no method. -/
def prepareMethod (ctx : Value) : SIO String := do
  let m ← gpS (← gp ctx "point") "method"
  if m != "" then pure m.toUpper
  else pure (opMethodOf (← opnameOf ctx))

def escurlS (s : String) : SIO String := do
  match (← escurl (.str s)) with
  | .str e => pure e
  | _ => pure s

def isJsonMedia (t : String) : Bool :=
  let media := (trimS ((t.splitOn ";").headD "")).toLower
  media == "application/json" || media == "text/json" || media.endsWith "+json"

/-- The declared JSON type alone, else every declared type in model order; nothing without a body. -/
def acceptOf (point : Value) : SIO (Option String) := do
  let res ← gp point "response"
  let media ← gpS res "media"
  let kind ← gpS res "kind"
  if media == "" then return none
  if kind == "json" then return some media
  let mut all : Array String := #[media]
  match (← gp res "alternatives") with
  | .list i =>
    for alt in (← listItems i) do
      let m ← gpS alt "media"
      if m != "" then all := all.push m
  | _ => pure ()
  return some (", ".intercalate all.toList)

def hasHeader (headers : Value) (name : String) : SIO Bool := do
  pure ((← keysof headers).any (fun k => k.toLower == name))

/-- A caller's accept wins. A declared request type replaces each JSON
    content-type, the SDK default, and leaves any other the caller set. -/
def mediaHeaders (point headers : Value) : SIO Value := do
  match (← acceptOf point) with
  | some a => if !(← hasHeader headers "accept") then sp headers "accept" (.str a)
  | none => pure ()
  let body ← gp point "body"
  let kind ← gpS body "kind"
  let media ← gpS body "media"
  if (kind == "raw" || kind == "json") && media != "" then
    for k in (← keysof headers) do
      if k.toLower == "content-type" && isJsonMedia (vs (← gp headers k)) then dp headers k
    if !(← hasHeader headers "content-type") then sp headers "content-type" (.str media)
  pure headers

/-- The form style of a cookie parameter: a list repeats the name, a map sends
    its own keys, and every value is percent-encoded. -/
def cookiePair (wire : String) (val : Value) : SIO String := do
  let esc (v : Value) : SIO String := do escurlS (← stringify v)
  let pairs ← match val with
    | .list i => do (← listItems i).mapM (fun x => do pure (wire ++ "=" ++ (← esc x)))
    | .map _ => do (← keysof val).mapM (fun k => do
        pure ((← escurlS k) ++ "=" ++ (← esc (← gp val k))))
    | _ => do pure #[wire ++ "=" ++ (← esc val)]
  pure ("; ".intercalate pairs.toList)

/-- The caller's cookie pieces with the named cookies removed: a cookie is one
    `;`-delimited piece, whatever its value holds. -/
def cookieKeep (header : String) (names : Array String) : Array String :=
  ((header.splitOn ";").toArray.map trimS).filter
    (fun cookie => cookie != "" && !(names.contains (trimS ((cookie.splitOn "=").headD ""))))

def prepareHeaders (ctx : Value) : SIO Value := do
  let options ← gp ctx "options"
  let base ← match (← gp options "headers") with
    | .map i => clone (.map i)
    | _ => newMap #[("content-type", .str "application/json")]
  let point ← gp ctx "point"
  let out ← mediaHeaders point base

  -- A header argument replaces a default of the same name, whatever its case.
  for (_, wire, val) in (← callArgs ctx "header") do
    if !(isNov val) then
      let key := wire.toLower
      for k in (← keysof out) do
        if k.toLower == key then dp out k
      sp out key (.str (← stringify val))

  -- A cookie argument travels in the cookie header, form serialized and
  -- percent-encoded, replacing a same-named cookie the caller's headers send.
  let sent := (← callArgs ctx "cookie").filter (fun (_, _, val) => !(isNov val))
  if 0 < sent.size then
    let mut names : Array String := #[]
    for (_, wire, val) in sent do
      match val with
      | .map _ => for k in (← keysof val) do names := names.push (← escurlS k)
      | _ => names := names.push wire
    let mut kept : Array String := #[]
    for k in (← keysof out) do
      if k.toLower == "cookie" then
        match (← gp out k) with
        | .str s => kept := kept ++ cookieKeep s names
        | _ => pure ()
        dp out k
    for (_, wire, val) in sent do
      let pair ← cookiePair wire val
      if pair != "" then kept := kept.push pair
    if 0 < kept.size then sp out "cookie" (.str ("; ".intercalate kept.toList))
  pure out

/-- The credential prefix (`Bearer`): `options.auth.prefix`, where makeOptions
    has merged the caller's `auth` over the model's, so the caller's prefix
    wins; with no `auth` map in the options, the model's
    `config.options.auth.prefix`; else none. Shared with the secrets feature,
    whose transport wrapper rewrites the header from the same rule. -/
def authPrefix (ctx : Value) : SIO String := do
  let options ← gp ctx "options"
  match (← gp options "auth") with
  | .map _ => gpS (← gp options "auth") "prefix"
  | _ =>
    let copts ← gp (← gp ctx "config") "options"
    gpS (← gp copts "auth") "prefix"

/-- apikey (with the configured auth prefix) becomes the authorization header. -/
def prepareAuth (ctx : Value) : SIO (Value × Option Value) := do
  let specV ← gp ctx "spec"
  match specV with
  | .map _ => do
    let headers ← gpMap specV "headers"
    let options ← gp ctx "options"
    -- `auth: null` is the documented way to suppress auth outright: NO
    -- authorization header, whatever the apikey says. Without this the
    -- withheld credential goes on the wire.
    --
    -- The ports that run options through validate against an optspec carrying
    -- an `auth` default can use absence as the signal (validate guarantees the
    -- key is present otherwise). lean's makeOptions has no optspec, so `auth`
    -- is ABSENT in the ordinary case and absence must stay the ordinary case.
    -- getpropRaw is the only reader that tells a STORED null from an absent
    -- key - gp collapses both to .noval - so the stored null alone suppresses.
    let authRaw ← getpropRaw options "auth"
    let apikey ← gpS options "apikey"
    if authRaw == .null || apikey == "" then do
      dp headers "authorization"
      pure (specV, none)
    else do
      let pfx ← authPrefix ctx
      let authval := if pfx != "" then pfx ++ " " ++ apikey else apikey
      sp headers "authorization" (.str authval)
      pure (specV, none)
  | _ => do
    let e ← mkErr "auth_no_spec" "Expected context spec property to be defined."
    pure (.noval, some e)

-- ---------------------------------------------------------------------------
-- transforms
-- ---------------------------------------------------------------------------

def omitKeys (v : Value) (names : Array String) : SIO Value := do
  match v with
  | .map _ =>
    let hit := (← keysof v).filter (fun k => names.contains k)
    if hit.isEmpty then pure v
    else
      let c ← clone v
      for k in hit do dp c k
      pure c
  | _ => pure v

def fieldArg (ctx : Value) (name : String) : SIO Bool := do
  let point ← gp ctx "point"
  for kind in #["header", "cookie", "query"] do
    for ad in (← argDefs point kind) do
      if (← gpS ad "name") == name then
        match (← gp ad "field") with
        | .bool true => return true
        | _ => pure ()
  pure false

/-- A header, cookie or query argument travels where prepareHeaders or
    prepareQuery sends it, so the body is built from the request data without it,
    unless the point marks it as a field the body keeps. -/
def routedArgNames (ctx : Value) : SIO (Array String) := do
  let mut names : Array String := #[]
  for kind in #["header", "cookie", "query"] do
    for (name, _, _) in (← callArgs ctx kind) do
      unless (← fieldArg ctx name) do names := names.push name
  pure names

def transformRequest (ctx : Value) : SIO Value := do
  let specV ← gp ctx "spec"
  match specV with
  | .map _ => sp specV "step" (.str "reqform")
  | _ => pure ()
  let point ← gp ctx "point"
  let reqdata ← omitKeys (← gp ctx "reqdata") (← routedArgNames ctx)
  let out ← match (← gp point "transform") with
    | .map i => do
      let reqform ← gp (.map i) "req"
      if isNov reqform then pure reqdata
      else do
        let input ← newMap #[("reqdata", reqdata)]
        transform input reqform
    | _ => pure reqdata
  omitKeys out #["$action"]

def transformResponse (ctx : Value) : SIO Value := do
  let specV ← gp ctx "spec"
  match specV with
  | .map _ => sp specV "step" (.str "resform")
  | _ => pure ()
  let resultV ← gp ctx "result"
  match resultV with
  | .map _ => do
    if !(truthy (← gp resultV "ok")) then pure .noval
    else do
      let point ← gp ctx "point"
      match (← gp point "transform") with
      | .map i => do
        let resform ← gp (.map i) "res"
        if isNov resform then pure .noval
        else do
          let ok ← gp resultV "ok"
          let status ← gp resultV "status"
          let stt ← gp resultV "statusText"
          let hdr ← gp resultV "headers"
          let body ← gp resultV "body"
          let resdata ← gp resultV "resdata"
          let resmatch ← gp resultV "resmatch"
          let input ← newMap #[("ok", ok), ("status", status), ("statusText", stt),
                               ("headers", hdr), ("body", body),
                               ("resdata", resdata), ("resmatch", resmatch)]
          let out ← transform input resform
          sp resultV "resdata" out
          pure out
      | _ => pure .noval
  | _ => pure .noval

/-- The text a transport sends for a body: a raw point's string as given,
    anything else as JSON, a JSON point's string scalar included. The
    reference decides from the value alone and sends any string as given. -/
def bodyText (point body : Value) : SIO (Option String) := do
  match body with
  | .noval | .null => return none
  | .str s => if (← gpS (← gp point "body") "kind") == "raw" then return some s
              else return some (← jsonify body)
  | _ => return some (← jsonify body)

/-- The request body: only data-input operations carry one, a raw point's as given. -/
def prepareBody (ctx : Value) : SIO Value := do
  if opInputOf (← opnameOf ctx) != "data" then return .noval
  let body ← gp (← gp ctx "point") "body"
  if (← gpS body "kind") == "raw" then gp (← gp ctx "reqdata") "$body"
  else transformRequest ctx

-- ---------------------------------------------------------------------------
-- graphql (transport)
--
-- GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
-- produces uses this code unchanged. The API-specific part — which operations
-- exist and what each one's document is — is model data, computed once by
-- apidef and emitted into Config.
--
-- Two jobs:
--
--   graphqlBody   — build { query, variables } for a point, binding the op's
--                   arguments to the document's declared variables.
--
--   graphqlErrors — lift a GraphQL failure into an SDK error. GraphQL reports
--                   failures as a top-level `errors` array under HTTP 200, so
--                   the status-driven path in resultBasic never sees them.
-- ---------------------------------------------------------------------------

/-- Content type every GraphQL-over-HTTP request uses. -/
def graphqlContentType : String := "application/json"

private def hasSub (hay needle : String) : Bool :=
  1 < (hay.splitOn needle).length

/-- Whether a comma-separated allow option names the item: whole names, any case. -/
def allowListHas (names item : String) : Bool :=
  item != "" && (names.splitOn ",").any (fun name => name.trim.toUpper == item.toUpper)

/-- Whether `options.allow.<key>` refuses the item. A string refuses what it does
not name, an empty one included, as the ts reference's `allowed` does, and any
other value refuses everything, a null or a non-map `allow` too; read raw, as gp
reads a null as absent. Only an ABSENT `allow` or key allows, and only a
hand-built context has one: makeOptions fills a nullish or missing list. -/
def allowRefuses (options : Value) (key item : String) : SIO Bool := do
  match (← lookupRaw options (.str "allow")) with
  | .noval => pure false
  | allow@(.map _) =>
    match (← lookupRaw allow (.str key)) with
    | .noval => pure false
    | .str s => pure !(allowListHas s item)
    | _ => pure true
  | _ => pure true

/-- Map a GraphQL error to the same error codes the HTTP path produces, so a
caller handles auth or rate limiting identically on both transports. Servers
put the machine-readable code in `extensions.code`; Linear-style APIs use
`extensions.type`. -/
def graphqlErrorCode (gqlerr : Value) : SIO String := do
  let ext ← gp gqlerr "extensions"
  let c ← gpS ext "code"
  let code ← if c == "" then gpS ext "type" else pure c
  let raw := code.toUpper
  if hasSub raw "AUTH" || hasSub raw "FORBIDDEN" || hasSub raw "UNAUTHENTICATED" then
    pure "request_auth"
  else if hasSub raw "RATELIMIT" || hasSub raw "RATE_LIMIT" || hasSub raw "TOO_MANY" then
    pure "request_ratelimit"
  else if hasSub raw "BAD_USER_INPUT" || hasSub raw "VALIDATION" || hasSub raw "INVALID" then
    pure "request_invalid"
  else
    pure "request_graphql"

/-- Build the request body for a GraphQL point.

Variables come from the op's own arguments: a named variable binds to the
like-named argument (`from`), and the input-object variable (empty `from`)
takes the request data as a whole — which is what makes a generated
create/update call look exactly like its REST equivalent. -/
def graphqlBody (ctx : Value) : SIO Value := do
  let gql ← gp (← gp ctx "point") "graphql"
  match gql with
  | .map _ => do
    -- reqmatch/reqdata hold the caller's arguments for THIS call; data/match
    -- hold the entity's current state. Which pair depends on whether the op
    -- takes match or data input. A named variable falls back to the current
    -- state, so updating a loaded entity with just {title} still binds the
    -- stored id the mutation requires.
    let datainput := opInputOf (← opnameOf ctx) == "data"
    let reqsrc ← asMap (← gp ctx (if datainput then "reqdata" else "reqmatch"))
    let datasrc ← asMap (← gp ctx (if datainput then "data" else "match"))
    let variables ← emptyMap
    let varlist ← match (← gp gql "vars") with
      | .list i => listItems i
      | _ => pure #[]
    for spec in varlist do
      match spec with
      | .map _ => do
        let name ← gpS spec "name"
        -- `from` is a Lean keyword, so the binding cannot take the field's
        -- own name.
        let varFrom ← gpS spec "from"
        if name != "" then
          if varFrom == "" then do
            -- The input object IS the request body. Strip the action
            -- selector, which is an SDK-side point discriminator, not an API
            -- field.
            let body ← emptyMap
            for k in (← keysof reqsrc) do
              if k != "$action" then sp body k (← gp reqsrc k)
            sp variables name body
          else do
            -- Only send variables the caller actually supplied: sending an
            -- explicit null would clear a field on many APIs.
            let v0 ← gp reqsrc varFrom
            let v ← if isNullish v0 then gp datasrc varFrom else pure v0
            if !(isNullish v) then sp variables name v
      | _ => pure ()
    newMap #[("query", ← gp gql "doc"), ("variables", variables)]
  | _ => pure .noval

/-- Inspect a decoded GraphQL response body and record a failure when the
server reported one. Returns true when an error was recorded.

Partial data (`data` alongside `errors`) is treated as failure: the REST
surface has no partial-success concept, and silently returning half an object
would be worse than failing. -/
def graphqlErrors (ctx : Value) : SIO Bool := do
  let resultV ← gp ctx "result"
  match resultV with
  | .map _ => do
    if (← gpS (← gp ctx "point") "kind") != "graphql" then pure false
    else
      let errors ← match (← gp (← gp resultV "body") "errors") with
        | .list i => listItems i
        | _ => pure #[]
      if errors.size == 0 then pure false
      else do
        let first := errors[0]!
        let m0 ← gpS first "message"
        let m1 := if m0 == "" then "graphql error" else m0
        let msg := if 1 < errors.size then
          m1 ++ " (+" ++ toString (errors.size - 1) ++ " more)" else m1
        let e ← mkErr (← graphqlErrorCode first) ("graphql: " ++ msg)
        sp resultV "err" e
        sp resultV "ok" (.bool false)
        pure true
  | _ => pure false

-- ---------------------------------------------------------------------------
-- result assembly
-- ---------------------------------------------------------------------------

def resultBasic (ctx : Value) : SIO Unit := do
  let responseV ← gp ctx "response"
  let resultV ← gp ctx "result"
  match responseV, resultV with
  | .map _, .map _ => do
    let st ← gp responseV "status"
    let stt ← gp responseV "statusText"
    sp resultV "status" st
    sp resultV "statusText" stt
    let status := jsNumber st
    if status >= 400.0 then do
      let msg := "request: " ++ numToString status ++ ": " ++ vs stt
      let prev ← gp resultV "err"
      let pm ← match prev with
        | .map _ => gpS prev "message"
        | _ => pure ""
      let full := if pm != "" then pm ++ ": " ++ msg else msg
      let e ← mkErr "request_status" full
      sp resultV "err" e
    else do
      let rerr ← gp responseV "err"
      if (← isErrV rerr) then sp resultV "err" rerr
  | _, _ => pure ()

/-- Response headers land on the result with lower-cased keys. -/
def resultHeaders (ctx : Value) : SIO Unit := do
  let resultV ← gp ctx "result"
  match resultV with
  | .map _ => do
    let out ← emptyMap
    let responseV ← gp ctx "response"
    match responseV with
    | .map _ => do
      match (← gp responseV "headers") with
      | .map i =>
        for k in (← keysof (.map i)) do
          let v ← gp (.map i) k
          sp out k.toLower v
      | _ => pure ()
    | _ => pure ()
    sp resultV "headers" out
  | _ => pure ()

/-- A header's value, whatever the case of its name. -/
def headerText (headers : Value) (name : String) : SIO String := do
  match headers with
  | .map _ =>
    for k in (← keysof headers) do
      if k.toLower == name then return (← jsString (← gp headers k))
    pure ""
  | _ => pure ""

def cleanText (ctx : Value) (s : String) : SIO String := do
  match (← clean ctx (.str s)) with
  | .str c => pure c
  | _ => pure s

/-- Whitespace runs as one space, trimmed. -/
def flattenSpace (s : String) : String := Id.run do
  let mut out := ""
  let mut space := false
  for c in s.toList do
    if c.isWhitespace then
      space := !out.isEmpty
    else
      if space then
        out := out.push ' '
        space := false
      out := out.push c
  return out

/-- Cleaned whole: a secret the bound would split could leave its prefix. -/
def bodyPreview (ctx : Value) (text : Value) : SIO String := do
  let flat ← cleanText ctx (flattenSpace (← jsString text))
  let cs := flat.toList
  pure (if cs.length > 160 then String.ofList (cs.take 160) ++ "..." else flat)

/-- A body that is not JSON. An HTTP failure keeps its own error, with the
    response described; otherwise the code tells a wrong content type from
    malformed JSON. -/
def unreadableBody (ctx : Value) (status : Float) (headers text sent failed : Value) :
    SIO Value := do
  let ctype ← headerText headers "content-type"
  let agent ← cleanText ctx (← headerText sent "user-agent")
  let preview ← match text with
    | .noval => pure ""
    | .null => pure ""
    | _ => do pure (", body: " ++ (← bodyPreview ctx text))
  let detail := "HTTP " ++ numToString status ++ ", content-type " ++
    (if ctype == "" then "none" else ctype) ++ ", user-agent " ++
    (if agent == "" then "transport default" else agent) ++ preview
  if (← isErrV failed) then
    let m ← gpS failed "message"
    sp failed "message" (.str (m ++ " (" ++ detail ++ ")"))
    pure failed
  else if ctype == "" || (ctype.toLower.splitOn "json").length > 1 then
    mkErr "response_json_invalid" ("response: body is not valid JSON (" ++ detail ++ ")")
  else
    mkErr "response_content_type" ("response: expected JSON, got " ++ ctype ++ " (" ++ detail ++ ")")

def resultBody (ctx : Value) : SIO Unit := do
  let responseV ← gp ctx "response"
  let resultV ← gp ctx "result"
  match responseV, resultV with
  | .map _, .map _ => do
    let body ← gp responseV "body"
    if truthy (← gp responseV "unreadable") then
      let specV ← gp ctx "spec"
      let sent ← match specV with
        | .map _ => gp specV "headers"
        | _ => pure .noval
      let e ← unreadableBody ctx (jsNumber (← gp resultV "status")) (← gp resultV "headers")
        body sent (← gp resultV "err")
      sp resultV "err" e
    else if !(isNov body) then sp resultV "body" body
  | _, _ => pure ()

-- ---------------------------------------------------------------------------
-- spec / url / request / response
-- ---------------------------------------------------------------------------

def makeSpec (ctx : Value) : SIO (Value × Option Value) := do
  let options ← gp ctx "options"
  let base ← gpS options "base"
  let pfx ← gpS options "prefix"
  let suffix ← gpS options "suffix"
  let point ← gp ctx "point"
  let parts ← match (← gp point "parts") with
    | .list i => pure (Value.list i)
    | _ => emptyList
  let aliasm ← emptyMap
  let spec ← newMap #[("base", .str base), ("prefix", .str pfx),
                      ("suffix", .str suffix), ("parts", parts),
                      ("alias", aliasm), ("step", .str "start")]
  sp ctx "spec" spec
  let method ← prepareMethod ctx
  sp spec "method" (.str method)
  if (← allowRefuses options "method" method) then
    let allowm ← gp (← gp options "allow") "method"
    let e ← mkErr "spec_method_allow"
      s!"Method \"{method}\" not allowed by SDK option allow.method value: \"{vs allowm}\""
    return (.noval, some e)
  sp spec "path" (.str (← preparePath ctx))
  sp spec "params" (← prepareParams ctx)
  sp spec "query" (← prepareQuery ctx)
  let headers ← prepareHeaders ctx
  sp spec "headers" headers
  if (← gpS point "kind") == "graphql" then do
    -- GraphQL addresses one endpoint: no path parts, no query string, and the
    -- body carries the operation. prepareBody is skipped deliberately — it
    -- only emits a body for data-input ops, whereas every GraphQL op posts
    -- one, including load/list/remove.
    sp spec "body" (← graphqlBody ctx)
    sp spec "path" (.str "")
    -- prepareQuery already copied the op's match arguments into the query
    -- string. Those same values are bound as operation variables, so leaving
    -- them would send /graphql?id=i1.
    sp spec "query" (← emptyMap)
    sp headers "content-type" (.str graphqlContentType)
  else do
    let body ← prepareBody ctx
    if !(isNov body) then sp spec "body" body
  let explain ← gp (← gp ctx "ctrl") "explain"
  if isMapV explain then sp explain "spec" spec
  prepareAuth ctx

/-- Each `{name}` in the text whose name holds no brace or slash. -/
partial def placeholders : List Char → List String
  | '{' :: rest =>
    let name := rest.takeWhile (fun c => c != '{' && c != '}' && c != '/')
    match rest.drop name.length with
    | '}' :: more =>
      if name.isEmpty then placeholders rest
      else ("{" ++ String.ofList name ++ "}") :: placeholders more
    | _ => placeholders rest
  | _ :: rest => placeholders rest
  | [] => []

/-- base/prefix/path/suffix joined, `{param}` substituted, query appended. -/
def makeUrl (ctx : Value) : SIO (Value × Option Value) := do
  let specV ← gp ctx "spec"
  match specV with
  | .map _ => do
    let base ← gpS specV "base"
    let pfx ← gpS specV "prefix"
    let path ← gpS specV "path"
    let suffix ← gpS specV "suffix"
    let arr ← newList #[.str base, .str pfx, .str path, .str suffix]
    let url0 ← joinurl arr
    let resmatch ← emptyMap
    let mut url := url0
    let params ← gp specV "params"
    for k in (← keysof params) do
      let v ← gp params k
      if !(isNov v) then do
        let enc ← escurl (.str (← jsString v))
        sp resmatch k v
        url := url.replace ("{" ++ k ++ "}") (vs enc)
    -- A placeholder left in the route would send the request to the wrong route.
    -- The base's own placeholders are server variables, resolved with the options.
    let base' := (base.toList.reverse.dropWhile (· == '/')).reverse
    let chars := url.toList
    let route := if base'.isPrefixOf chars then chars.drop base'.length else chars
    let unfilled := placeholders route
    if !unfilled.isEmpty then
      let e ← mkErr "url_param_missing"
        ("URL path has no value for " ++ ", ".intercalate unfilled ++ ".")
      return (.str "", some e)
    let query ← gp specV "query"
    let mut qsep := "?"
    for k in (← keysof query) do
      let v ← gp query k
      if !(isNov v) then do
        let ek ← escurl (.str k)
        let ev ← escurl (.str (← jsString v))
        sp resmatch k v
        url := url ++ qsep ++ vs ek ++ "=" ++ vs ev
        qsep := "&"
    let resultV ← gp ctx "result"
    match resultV with
    | .map _ => sp resultV "resmatch" resmatch
    | _ => pure ()
    pure (.str url, none)
  | _ => do
    let e ← mkErr "url_no_spec" "Expected context spec property to be defined."
    pure (.str "", some e)

/-- Prepare the transport call: the response/result carriers must exist. -/
def makeRequest (ctx : Value) : SIO (Value × Option Value) := do
  let specV ← gp ctx "spec"
  match specV with
  | .map _ => sp specV "step" (.str "request")
  | _ => pure ()
  let _ ← gpMap ctx "response"
  let _ ← gpMap ctx "result"
  pure ((← gp ctx "response"), none)

/-- The initial result carrier the pipeline fills in. -/
def makeResult (ctx : Value) : SIO Value := do
  let resmatch ← emptyMap
  let res ← newMap #[("ok", .bool false), ("status", .num (-1.0)),
                     ("statusText", .str ""), ("resmatch", resmatch)]
  sp ctx "result" res
  pure res

/-- How many path segments a point has, and whether its path ends in a
    parameter. A record route ends in the record's identifier (/boards/{id});
    a cross-reference that also returns the entity ends in the relationship's
    name (/posts/{id}/author). That, then fewest segments, is what tells the
    entity's own route from a cross-reference. The same rule runs at
    generation time, in helpers/opShape.ts — both sides must move together. -/
def pointShape (pt : Value) : SIO (Nat × Bool) := do
  match (← gp pt "parts") with
  | .list i =>
    let items ← listItems i
    if items.size == 0 then pure (0, false)
    else pure (items.size, (vs items[items.size - 1]!).startsWith "{")
  | _ => pure (0, false)

/-- Select the endpoint for this operation: the single point, else the first
    whose `select.exist` keys are all present and whose `$action` agrees. An
    op `options.allow.op` does not name is refused before any endpoint is
    resolved, and an `$action` no point declares is refused rather than
    answered with a different endpoint. -/
def makePoint (ctx : Value) : SIO Value := do
  let op ← gp ctx "op"
  let opname ← gpS op "name"
  -- Whole names over the comma list, in any case, as the ts and go references
  -- match.
  let options ← gp ctx "options"
  if (← allowRefuses options "op" opname) then
    let allowv ← gp (← gp options "allow") "op"
    return (← mkErr "point_op_allow"
      s!"Operation \"{opname}\" not allowed by SDK option allow.op value: \"{vs allowv}\"")
  let input0 ← gpS op "input"
  let input := if input0 == "" then "match" else input0
  -- The call's own arguments, then the entity's current state. `$action` is
  -- only ever an argument, so it is read from the first alone.
  let reqsel ← gp ctx ("req" ++ input)
  let statesel ← gp ctx input
  let action ← gp reqsel "$action"
  let pts ← match (← gp op "points") with
    | .list i => listItems i
    | _ => pure #[]
  if pts.size == 0 then pure .noval
  else if pts.size == 1 then do
    sp ctx "point" (pts[0]!)
    pure (pts[0]!)
  else do
    let mut chosen : Value := .noval
    for pt in pts do
      if isNov chosen then
        let sel ← gp pt "select"
        let mut ok := true
        match (← gp sel "exist") with
        | .list i =>
          for ek in (← listItems i) do
            let k := vs ek
            if isNov (← gp reqsel k) && isNov (← gp statesel k) then ok := false
        | _ => pure ()
        if ok && ((← gp sel "$action") == action) then
          chosen := pt
    if isNov chosen then
      if !(isNov action) then
        return (← mkErr "point_action_invalid"
          s!"Operation \"{opname}\" action \"{← jsString action}\" is not valid.")
      -- select.exist can list more than the params needed to pick a point (for
      -- /boards/{id} it is Trello's 17 optional query-includes), so a plain
      -- {id} call matches NOTHING and the loop above chose no point at all.
      -- Fall back to the entity's own route rather than sending nowhere. Only
      -- an actionless call gets that fallback: an action nothing declares is
      -- the caller's error, and the entity's own route is a different request.
      let mut best := pts[0]!
      for cand in pts do
        let (candLen, candTerm) ← pointShape cand
        let (bestLen, bestTerm) ← pointShape best
        if candTerm && !bestTerm then
          best := cand
        else if candTerm == bestTerm && candLen < bestLen then
          best := cand
      chosen := best
    if !(isNov chosen) then sp ctx "point" chosen
    pure chosen

/-- The transport payload: method, headers and (for data ops) the body. -/
def makeFetchDef (ctx : Value) : SIO Value := do
  let specV ← gp ctx "spec"
  let method ← gpS specV "method"
  let headers ← asMap (← gp specV "headers")
  let out ← newMap #[("method", .str method), ("headers", headers)]
  let body ← gp specV "body"
  if !(isNov body) then sp out "body" body
  pure out

/-- The transport step. In test mode the client answers from its own store, so
    this is only reached for live calls; the concrete send is injected by the
    runtime (SdkRuntime.curlFetch) to keep this layer transport-agnostic. -/
def fetcher (ctx : Value) (url : String) (fetchdef : Value) : SIO Value := do
  let out ← emptyMap
  sp out "url" (.str url)
  sp out "fetchdef" fetchdef
  sp ctx "fetch" out
  pure out

-- ---------------------------------------------------------------------------
-- features
-- ---------------------------------------------------------------------------

/-- The client's ordered feature list. -/
def featureList (client : Value) : SIO Value := do
  match (← gp client "features") with
  | .list i => pure (Value.list i)
  | _ => do
    let l ← emptyList
    sp client "features" l
    pure l

/-- Add a feature, honouring `__before__` / `__after__` / `__replace__`
    placement against the named feature (append by default). -/
def featureAdd (client : Value) (feat : Value) : SIO Unit := do
  let feats ← featureList client
  let items ← match feats with
    | .list i => listItems i
    | _ => pure #[]
  let nm ← gpS feat "name"
  let before ← gpS feat "__before__"
  let after ← gpS feat "__after__"
  let replace ← gpS feat "__replace__"
  let mut out : Array Value := #[]
  let mut placed := false
  for f in items do
    let fn ← gpS f "name"
    if replace != "" && fn == replace then
      out := out.push feat
      placed := true
    else if before != "" && fn == before then
      out := out.push feat
      out := out.push f
      placed := true
    else if after != "" && fn == after then
      out := out.push f
      out := out.push feat
      placed := true
    else if fn == nm then
      out := out.push feat
      placed := true
    else
      out := out.push f
  if !placed then out := out.push feat
  sp client "features" (← newList out)

/-- Initialise every active feature (idempotent: marks `inited`). -/
def featureInit (client : Value) (ctx : Value) : SIO Unit := do
  let feats ← featureList client
  match feats with
  | .list i =>
    for f in (← listItems i) do
      if truthy (← gp f "active") && !(truthy (← gp f "inited")) then do
        sp f "inited" (.bool true)
        sp f "ctx" ctx
  | _ => pure ()

/-- Dispatch a pipeline stage to every active feature that defines the hook. -/
def featureHook (client : Value) (stage : String) (ctx : Value) : SIO Unit := do
  let feats ← featureList client
  match feats with
  | .list i =>
    for f in (← listItems i) do
      if truthy (← gp f "active") then do
        let hooks ← gp f "hooks"
        let h ← gp hooks stage
        match h with
        | .func fid => do
          let inj ← getDummyInj
          let _ ← callFunc fid inj ctx stage ctx
          pure ()
        | _ => pure ()
  | _ => pure ()

/-- Fold the transport response into the result (basic/headers/body/resform). -/
def makeResponse (ctx : Value) : SIO (Value × Option Value) := do
  let specV ← gp ctx "spec"
  let responseV ← gp ctx "response"
  let resultV ← gp ctx "result"
  match specV, responseV, resultV with
  | .map _, .map _, .map _ => do
    sp specV "step" (.str "response")
    resultBasic ctx
    resultHeaders ctx
    resultBody ctx
    -- GraphQL reports failures as a top-level `errors` array under HTTP 200,
    -- so resultBasic's status check never sees them. Lift them here, before
    -- the response transform tries to unwrap data that is not there.
    let _ ← graphqlErrors ctx
    let _ ← transformResponse ctx
    let errv ← gp resultV "err"
    if !(← isErrV errv) then sp resultV "ok" (.bool true)
    pure (responseV, none)
  | _, _, _ => pure (.noval, none)

end SdkUtility
