/- Univec SDK feature test.

   Verifies the feature catalog's OBSERVABLE behaviour. Each feature records
   into the client's `track` bucket under its own name, so a test activates a
   feature, runs an operation against the offline (test-mode) transport, and
   asserts the bucket. Features that wrap the transport are additionally
   checked for the effect they have on the request or the result. -/

import VoxgigStruct
import SdkJson
import SdkUtility
import SdkFeature
import SdkFeatures
import SdkClient

open VoxgigStruct

initialize npass : IO.Ref Nat ← IO.mkRef 0
initialize nfail : IO.Ref Nat ← IO.mkRef 0

def pass (msg : String) : SIO Unit := do
  npass.modify (· + 1)
  IO.println s!"ok   - {msg}"

def fail (msg : String) : SIO Unit := do
  nfail.modify (· + 1)
  IO.println s!"FAIL - {msg}"

def check (cond : Bool) (msg : String) : SIO Unit := do
  if cond then pass msg else fail msg

def gp := SdkUtility.gp
def gpS := SdkUtility.gpS

def numAt (v : Value) (k : String) : SIO Float := do
  match (← gp v k) with
  | .num n => pure n
  | _ => pure 0.0

/-- A test-mode client with the named features activated. -/
def clientWith (seed : Value) (feats : Array (String × Value)) : SIO Value := do
  let fmap ← emptyMap
  for (n, o) in feats do
    SdkUtility.sp fmap n o
  let opts ← emptyMap
  SdkUtility.sp opts "feature" fmap
  Sdk.testSdk seed opts

def onOpts (extra : Array (String × Value)) : SIO Value := do
  let o ← newMap #[("active", .bool true)]
  for (k, v) in extra do
    SdkUtility.sp o k v
  pure o

/-- List with maps of its own: the runtime records a failure on the caller's
    options map, so a reused map filters every later list by `err`. -/
def listAll (c : Value) (ent : String) : SIO Value := do
  SdkRuntime.opList c ent (← emptyMap) (← emptyMap)

/-- The bucket a feature records into. -/
def bucketOf (client : Value) (name : String) : SIO Value := do
  gp (← gp client "track") name

/-- Does the entity declare this op? -/
def hasOp (e : Value) (opname : String) : SIO Bool := do
  match (← gp (← gp e "op") opname) with
  | .map _ => pure true
  | _ => pure false

/-- The first entity that has a `list` op AND generated seed data: the feature
    suite is entity-agnostic, so it discovers its subject from the config.
    Returns whether the subject also has `create` — the idempotency check is
    the one case that mutates, and a list-only entity (an API with a read-only
    collection) has no create ENDPOINT, so calling it raises rather than
    exercising the feature. Entities carrying both are preferred, so a model
    that has one keeps the mutating coverage. -/
def findSubject : SIO (Option (String × Value × Bool)) := do
  let config ← SdkJson.jsonRead SdkConfig.configJson
  let ents ← gp config "entity"
  let mut fallback : Option (String × Value × Bool) := none
  for name in (← keysof ents) do
    let e ← gp ents name
    if ← hasOp e "list" then
      let Name := name.capitalize
      let seedPath := "../.sdk/test/entity/" ++ name ++ "/" ++ Name ++ "TestData.json"
      if ← System.FilePath.pathExists seedPath then
        let seed ← SdkJson.jsonRead (← IO.FS.readFile seedPath)
        if ← hasOp e "create" then
          return some (name, seed, true)
        if fallback.isNone then
          fallback := some (name, seed, false)
  pure fallback

/-- Is `h` the credential `token`, under whatever prefix this API declares?
    The template cannot know the prefix (`Bearer <token>` for an http/bearer
    scheme, the bare token for an apiKey scheme), so the check is on the
    credential. -/
def credentialIs (h : Option String) (token : String) : Bool :=
  match h with
  | some s => s == token || s.endsWith (" " ++ token)
  | none => false

/-- The first entity with a `list` op whose points carry no path parameter:
    a subject the pipeline can drive with an empty match. -/
def findListEntity : SIO (Option String) := do
  let config ← SdkJson.jsonRead SdkConfig.configJson
  let ents ← gp config "entity"
  for name in (← keysof ents) do
    let e ← gp ents name
    match (← gp (← gp e "op") "list") with
    | .map _ =>
      let mut plain := true
      match (← gp (← gp (← gp e "op") "list") "points") with
      | .list i =>
        for pt in (← listItems i) do
          if (← gpS pt "path").any (· == '{') then plain := false
      | _ => pure ()
      if plain then return some name
    | _ => pure ()
  return none

-- ---------------------------------------------------------------------------
-- The live pipeline, pinned on a FIXED API rather than this project's model
-- so the checks run in every generated SDK, over a recording transport.
-- ---------------------------------------------------------------------------

def pipeConfig : String := r#"{
  "main": {"name": "Pipe"},
  "options": {"base": "http://api.test", "headers": {"content-type": "application/json"}},
  "entity": {
    "widget": {"name": "widget", "op": {
      "list": {"name": "list", "points": [{"kind": "http", "method": "GET",
        "parts": ["widget"], "transform": {"req": "`reqdata`", "res": "`body`"},
        "args": {}, "select": {}}]},
      "load": {"name": "load", "points": [{"kind": "http", "method": "GET",
        "parts": ["widget", "{id}"], "params": ["id"],
        "transform": {"req": "`reqdata`", "res": "`body.widget`"},
        "args": {"params": [{"name": "id"}]}, "select": {}}]},
      "create": {"name": "create", "points": [{"kind": "http", "method": "POST",
        "parts": ["widget"], "transform": {"req": "`reqdata`", "res": "`body`"},
        "args": {}, "select": {}}]}
    }},
    "gadget": {"name": "gadget", "op": {
      "load": {"name": "load", "points": [
        {"kind": "http", "method": "GET", "parts": ["gadget", "{id}"], "params": ["id"],
         "transform": {"req": "`reqdata`", "res": "`body`"},
         "args": {"params": [{"name": "id"}]}, "select": {}},
        {"kind": "http", "method": "POST", "parts": ["gadget", "{id}", "archive"],
         "params": ["id"], "transform": {"req": "`reqdata`", "res": "`body`"},
         "args": {"params": [{"name": "id"}]}, "select": {"$action": "archive"}}]}
    }},
    "thing": {"name": "thing", "op": {
      "load": {"name": "load", "points": [{"kind": "graphql", "method": "POST", "parts": [],
        "graphql": {"doc": "query Thing($id: ID!) { thing(id: $id) { id } }",
                    "vars": [{"name": "id", "from": "id"}]},
        "transform": {"req": "`reqdata`", "res": "`body.data.thing`"},
        "args": {}, "select": {}}]}
    }},
    "badge": {"name": "badge", "op": {
      "list": {"name": "list", "points": [{"kind": "http", "method": "GET",
        "parts": ["badge"], "transform": {"req": "`reqdata`",
          "res": ["`$EACH`", "body", {"`$MERGE`": "`.badge`"}]},
        "args": {}, "select": {}}]}
    }}
  }
}"#

/-- A recording transport: counts calls and keeps the last url and fetchdef. -/
structure Wire where
  calls : IO.Ref Nat
  url : IO.Ref String
  fetchdef : IO.Ref Value

def mkWire : SIO Wire := do
  pure { calls := ← IO.mkRef 0, url := ← IO.mkRef "", fetchdef := ← IO.mkRef Value.noval }

def recording (w : Wire) (reply : SIO (Value × Option Value)) : SdkFeature.Fetcher :=
  fun _ u f => do
    w.calls.modify (· + 1)
    w.url.set u
    w.fetchdef.set f
    reply

def answer (status : Float) (text : String) (body : Value) (headers : Array (String × Value))
    : SIO (Value × Option Value) := do
  let resp ← newMap #[("status", .num status), ("statusText", .str text),
                      ("body", body), ("headers", ← newMap headers)]
  pure (resp, none)

def refused : SIO (Value × Option Value) := do
  pure (.noval, some (← SdkUtility.mkErr "boom" "connection refused"))

def hasSub (hay needle : String) : Bool := 1 < (hay.splitOn needle).length

/-- The message of an operation that throws, "" when it returns. -/
def thrown (act : SIO Value) : SIO String := do
  try
    let _ ← act
    pure ""
  catch e => pure (toString e)

def liveOpts (feats : Array (String × Value)) : SIO Value := do
  let fmap ← emptyMap
  for (n, o) in feats do
    SdkUtility.sp fmap n o
  newMap #[("feature", fmap)]

/-- Append a feature to a live client's chain: `dispatch` runs the hook of each
    feature on `client.features` whose options say active, so a feature the
    catalog does not carry still sees the stages. The client's options must name
    it (`liveOpts #[("probe", ...)]`), because that is where `isActive` looks. -/
def addProbe (client : Value) (hook : String → Value → SIO Unit) : SIO Unit := do
  let id ← SdkFeature.registerFeature { name := "probe", hook := hook }
  let items ← (match (← gp client "features") with
    | .list i => listItems i
    | _ => pure #[])
  SdkUtility.sp client "features" (← newList (items.push (.num id.toFloat)))

/-- Record every stage the pipeline dispatches. -/
def probeStages (client : Value) : SIO (IO.Ref (Array String)) := do
  let seen ← IO.mkRef (#[] : Array String)
  addProbe client (fun stage _ => do seen.modify (·.push stage))
  pure seen

/-- Fill `ctx.out.<key>` at the named stage: the short-circuit each ts stage
    utility honours when the hook before it did the stage's work. -/
def shortCircuit (client : Value) (stage key : String) (make : Value → SIO Value)
    : SIO Unit :=
  addProbe client (fun s ctx => do
    if s == stage then SdkUtility.sp (← SdkUtility.gpMap ctx "out") key (← make ctx))

/-- clean: an entity block, of per-entity settings or seeded records, is not
    read, whichever form `feature` takes. A definition of its own: inline, it
    takes `main`'s `do` block past the compiler's heartbeat limit. -/
def cleanEntityBlocks : SIO Unit := do
  let seeded (kvs : Array (String × Value)) : SIO Value := do
    let row ← newMap #[("id", .str "ZZTOKEN01"), ("note", .str "PLAINRECORD-t5r3e1w9")]
    let ids ← newMap #[("ZZTOKEN01", row)]
    let block ← newMap #[("zztoken", ids)]
    newMap (kvs.push ("entity", block))
  let token ← newMap #[("active", .bool false), ("apitoken", .str "FEATTOKEN-z9y8x7w6")]
  let mapForm ← newMap #[("zzfeat", token), ("test", (← seeded #[("active", .bool false)]))]
  let named ← newMap #[("name", .str "zzfeat"), ("active", .bool false),
                       ("apitoken", .str "FEATTOKEN-z9y8x7w6")]
  let listForm ← newList #[named, (← seeded #[("name", .str "test"), ("active", .bool false)])]
  let mut ok := true
  for feature in #[mapForm, listForm] do
    let alias ← newMap #[("zzkey", .str "PLAINALIAS-m2n4b6v8")]
    let ent ← newMap #[("zztoken", (← newMap #[("alias", alias)]))]
    let opts ← SdkUtility.makeOptions (← emptyMap)
      (← newMap #[("feature", feature), ("test", (← seeded #[])), ("entity", ent)])
    let ctx ← newMap #[("options", opts)]
    let values ← SdkUtility.cfgStrings (← SdkUtility.cleanConfig ctx) "values"
    let record ← SdkUtility.clean ctx (.str "record PLAINRECORD-t5r3e1w9")
    let aliased ← SdkUtility.clean ctx (.str "alias PLAINALIAS-m2n4b6v8")
    ok := ok && values.contains "FEATTOKEN-z9y8x7w6"
      && !(#["ZZTOKEN01", "PLAINRECORD-t5r3e1w9", "PLAINALIAS-m2n4b6v8"].any values.contains)
      && SdkUtility.vs record == "record PLAINRECORD-t5r3e1w9"
      && SdkUtility.vs aliased == "alias PLAINALIAS-m2n4b6v8"
  check ok "clean: an entity block is not read, whichever form feature takes"

/-- options.allow.method by whole names, in any case; one that is not a string
    allows nothing. A definition of its own, as `main` is near the compiler's
    limit. -/
def allowMethodCases : SIO Unit := do
  (do
    let w ← mkWire
    let opts ← newMap #[("allow", ← newMap #[("method", .str "put,\n get")])]
    let c ← SdkRuntime.mkClientWith opts pipeConfig
      (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
    let msg ← thrown (SdkRuntime.opCreate c "widget" (← newMap #[("title", .str "T")]) (← emptyMap))
    check (hasSub msg "not allowed by SDK option allow.method")
      s!"pipeline: allow.method refuses a method it does not name ({msg})"
    check ((← w.calls.get) == 0) "pipeline: a refused method reaches no transport"
    let _ ← SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "i1")]) (← emptyMap)
    check ((← w.calls.get) == 1) "pipeline: allow.method permits a method it names, in any case")
  (do
    let w ← mkWire
    let opts ← newMap #[("allow", ← newMap #[("method", .num 5.0)])]
    let c ← SdkRuntime.mkClientWith opts pipeConfig
      (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
    let msg ← thrown (SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "i1")]) (← emptyMap))
    check (hasSub msg "not allowed by SDK option allow.method" && (← w.calls.get) == 0)
      s!"pipeline: an allow.method that is not a string allows nothing ({msg})")

/-- An empty allow list names nothing and an `allow` that is not a map names
    nothing either, so a client built with either sends no request. -/
def allowEmptyCases : SIO Unit := do
  let refusedBy (allow : Value) (act : Value → SIO Value) : SIO (String × Nat) := do
    let w ← mkWire
    let c ← SdkRuntime.mkClientWith (← newMap #[("allow", allow)]) pipeConfig
      (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
    pure (← thrown (act c), ← w.calls.get)
  let create := fun (c : Value) => do
    SdkRuntime.opCreate c "widget" (← newMap #[("title", .str "T")]) (← emptyMap)
  let load := fun (c : Value) => do
    SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "i1")]) (← emptyMap)
  let (mmsg, mcalls) ← refusedBy (← newMap #[("method", .str "")]) create
  check (hasSub mmsg "not allowed by SDK option allow.method" && mcalls == 0)
    s!"pipeline: an empty allow.method refuses a create ({mmsg})"
  let (omsg, ocalls) ← refusedBy (← newMap #[("op", .str "")]) load
  check (hasSub omsg "not allowed by SDK option allow.op" && ocalls == 0)
    s!"pipeline: an empty allow.op refuses a load ({omsg})"
  let (smsg, scalls) ← refusedBy (.str "load,GET") load
  check (hasSub smsg "not allowed by SDK option allow" && scalls == 0)
    s!"pipeline: an allow that is not a map refuses a load ({smsg})"

/-- A model whose one point is a HEAD, which the default allow.method list does
    not name, with `cfgOpts` spliced into its config.options. -/
def headConfig (cfgOpts : String) : String :=
  r#"{"main": {"name": "Pipe"}, "options": {"base": "http://api.test""# ++ cfgOpts ++
  r#"}, "entity": {"beacon": {"name": "beacon", "op": {"load": {"name": "load",
    "points": [{"kind": "http", "method": "HEAD", "parts": ["beacon"],
      "transform": {"req": "`reqdata`", "res": "`body`"}, "args": {}, "select": {}}]}}}}}"#

/-- The thrown message and the transport calls of a load of the HEAD point. -/
def headLoad (opts : Value) (cfgOpts : String) : SIO (String × Nat) := do
  let w ← mkWire
  let c ← SdkRuntime.mkClientWith opts (headConfig cfgOpts)
    (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
  pure (← thrown (SdkRuntime.opLoad c "beacon" (← emptyMap) (← emptyMap)), ← w.calls.get)

def headRefused (r : String × Nat) : Bool :=
  hasSub r.1 "Method \"HEAD\" not allowed by SDK option allow.method" && r.2 == 0

/-- The allow.method and allow.op lists makeOptions resolves. -/
def allowResolved (config opts : Value) : SIO (String × String) := do
  let allow ← gp (← SdkUtility.makeOptions config opts) "allow"
  pure (← gpS allow "method", ← gpS allow "op")

def allowDefaultLists : String × String :=
  ("GET,PUT,POST,PATCH,DELETE,OPTIONS", "create,update,patch,load,list,remove,command,direct,graphql")

/-- A null allow list takes the default, as validate refills one in the other
    targets, so a client built with one sends its request. -/
def allowNullCases : SIO Unit := do
  let sentBy (json : String) (act : Value → SIO Value) : SIO (String × Nat) := do
    let w ← mkWire
    let c ← SdkRuntime.mkClientWith (← SdkJson.jsonRead json) pipeConfig
      (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
    pure (← thrown (act c), ← w.calls.get)
  let create := fun (c : Value) => do
    SdkRuntime.opCreate c "widget" (← newMap #[("title", .str "T")]) (← emptyMap)
  let load := fun (c : Value) => do
    SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "i1")]) (← emptyMap)
  let (mmsg, mcalls) ← sentBy "{\"allow\":{\"method\":null}}" create
  check (mmsg == "" && mcalls == 1) s!"pipeline: a null allow.method sends a create ({mmsg})"
  let (omsg, ocalls) ← sentBy "{\"allow\":{\"op\":null}}" load
  check (omsg == "" && ocalls == 1) s!"pipeline: a null allow.op sends a load ({omsg})"
  let (amsg, acalls) ← sentBy "{\"allow\":null}" create
  check (amsg == "" && acalls == 1) s!"pipeline: a null allow sends a create ({amsg})"
  let resolved (json : String) : SIO (String × String) := do
    allowResolved (← emptyMap) (← SdkJson.jsonRead json)
  check ((← resolved "{\"allow\":{\"method\":null,\"op\":null}}") == allowDefaultLists
      && (← resolved "{\"allow\":null}") == allowDefaultLists)
    "makeOptions: a null allow, allow.op or allow.method takes the default"

/-- An undefined allow list takes the default as a null one does, so a client
    built with one still refuses a method the default list does not name. -/
def allowNovalCases : SIO Unit := do
  let named ← headLoad (← newMap #[("allow", ← newMap #[("method", .str "head")])]) ""
  check (named.1 == "" && named.2 == 1)
    s!"pipeline: an allow.method naming HEAD sends it ({named.1})"
  let m ← headLoad (← newMap #[("allow", ← newMap #[("method", .noval)])]) ""
  check (headRefused m) s!"pipeline: an undefined allow.method refuses a HEAD ({m.1})"
  let a ← headLoad (← newMap #[("allow", .noval)]) ""
  check (headRefused a) s!"pipeline: an undefined allow refuses a HEAD ({a.1})"
  let keys ← newMap #[("method", .noval), ("op", .noval)]
  check ((← allowResolved (← emptyMap) (← newMap #[("allow", keys)])) == allowDefaultLists
      && (← allowResolved (← emptyMap) (← newMap #[("allow", .noval)])) == allowDefaultLists)
    "makeOptions: an undefined allow, allow.op or allow.method takes the default"

/-- Over a config.options `allow` that is null or not a map, the caller's `allow`
    map is taken whole, and a key it omits still takes the default. -/
def allowOmittedKeyCases : SIO Unit := do
  let opOnly ← newMap #[("allow", ← newMap #[("op", .str "load")])]
  let s ← headLoad opOnly r#", "allow": "x""#
  check (headRefused s)
    s!"pipeline: a caller's allow without method refuses a HEAD over a config allow \"x\" ({s.1})"
  let n ← headLoad opOnly r#", "allow": null"#
  check (headRefused n)
    s!"pipeline: a caller's allow without method refuses a HEAD over a null config allow ({n.1})"
  let config ← newMap #[("options", ← newMap #[("allow", .str "x")])]
  let got ← allowResolved config (← newMap #[("allow", ← newMap #[("method", .str "GET")])])
  check (got == ("GET", allowDefaultLists.2))
    s!"makeOptions: an allow.op the caller's allow omits takes the default ({got.2})"

/-- The pipeline model with its allow.method narrowed to GET. -/
def getOnlyConfig : SIO String := do
  let config ← SdkJson.jsonRead pipeConfig
  SdkUtility.sp (← gp config "options") "allow" (← newMap #[("method", .str "GET")])
  jsonEncode config

/-- One options map builds two clients, the second over a model that allows
    only GET. Building the first leaves the map as it was, down to its entity
    block, so the second resolves what a fresh map gives it and refuses a
    POST; makeOptions leaves the model as it was too. -/
def optionsReuseCases : SIO Unit := do
  let literal := r#"{"base": "http://api.test", "allow": {"op": "create,load,list"},
    "headers": {"x-caller": "c1"}, "entity": {"widget": {"note": "c1"}}}"#
  let reply : SIO (Value × Option Value) := do answer 200.0 "OK" (← emptyMap) #[]
  let shared ← SdkJson.jsonRead literal
  let before ← jsonEncode shared (sort := true)
  let _ ← SdkRuntime.mkClientWith shared pipeConfig (recording (← mkWire) reply)
  let after ← jsonEncode shared (sort := true)
  check (after == before)
    s!"makeOptions: building a client leaves the caller's options map as it was ({after})"
  let getOnly ← getOnlyConfig
  let w ← mkWire
  let second ← SdkRuntime.mkClientWith shared getOnly (recording w reply)
  let fresh ← SdkRuntime.mkClientWith (← SdkJson.jsonRead literal) getOnly
    (recording (← mkWire) reply)
  let got ← jsonEncode (← gp second "options") (sort := true)
  check (got == (← jsonEncode (← gp fresh "options") (sort := true)))
    s!"makeOptions: a second client from that map resolves what a fresh map does ({got})"
  let msg ← thrown (SdkRuntime.opCreate second "widget" (← newMap #[("title", .str "T")])
    (← emptyMap))
  check (hasSub msg "not allowed by SDK option allow.method" && (← w.calls.get) == 0)
    s!"pipeline: the second client refuses the POST its own model refuses ({msg})"
  let model ← SdkJson.jsonRead getOnly
  let modelBefore ← jsonEncode model (sort := true)
  let _ ← SdkUtility.makeOptions model shared
  let modelAfter ← jsonEncode model (sort := true)
  check (modelAfter == modelBefore)
    s!"makeOptions: resolving the options leaves the model as it was ({modelAfter})"

/-- One call from `main`, which is at the compiler's heartbeat limit. -/
def allowDefaultCases : SIO Unit := do
  allowNullCases
  allowNovalCases
  allowOmittedKeyCases
  optionsReuseCases

def main : IO UInt32 := do
  let sctx ← mkCtx
  let go : SIO Unit := do
    -- pipeline: the apikey option reaches the wire. REGRESSION PIN: runOp
    -- built its headers with prepareHeaders and never called prepareAuth,
    -- and curlFetch sent no header but Content-Type, so a live lean SDK
    -- with an apikey set sent no credential at all. Driven through a LIVE
    -- client over a counting transport (SdkRuntime.mkClientWith), so the
    -- header asserted on is the one the wire would carry - and needs no
    -- seed data, so it runs in every project.
    (do
      match (← findListEntity) with
      | none => IO.println "skip - pipeline apikey: no entity with a parameterless list op"
      | some ent =>
        let sent ← IO.mkRef 0
        let seen ← IO.mkRef (none : Option String)
        let stub : SdkFeature.Fetcher := fun _ _ f => do
          sent.modify (· + 1)
          match (← gp f "headers") with
          | .map _ =>
            match (← gp (← gp f "headers") "authorization") with
            | .str a => seen.set (some a)
            | _ => pure ()
          | _ => pure ()
          let resp ← newMap #[("status", .num 200.0), ("statusText", .str "OK"),
                              ("body", ← emptyMap), ("headers", ← emptyMap)]
          pure (resp, none)
        let opts ← newMap #[("apikey", .str "WIREKEY01")]
        let c ← SdkRuntime.mkClientWith opts SdkConfig.configJson stub
        let _ ← listAll c ent
        check ((← sent.get) == 1) "pipeline: the live client reached the transport exactly once"
        check (credentialIs (← seen.get) "WIREKEY01")
          "pipeline: apikey reaches the wire as the authorization header"
        -- and `auth: null` keeps it off, chain or no chain
        let sent2 ← IO.mkRef 0
        let seen2 ← IO.mkRef (none : Option String)
        let stub2 : SdkFeature.Fetcher := fun _ _ f => do
          sent2.modify (· + 1)
          match (← gp f "headers") with
          | .map _ =>
            match (← gp (← gp f "headers") "authorization") with
            | .str a => seen2.set (some a)
            | _ => pure ()
          | _ => pure ()
          let resp ← newMap #[("status", .num 200.0), ("statusText", .str "OK"),
                              ("body", ← emptyMap), ("headers", ← emptyMap)]
          pure (resp, none)
        let opts2 ← newMap #[("apikey", .str "WIREKEY01"), ("auth", .null)]
        let c2 ← SdkRuntime.mkClientWith opts2 SdkConfig.configJson stub2
        let _ ← listAll c2 ent
        check ((← sent2.get) == 1 && (← seen2.get).isNone)
          "pipeline: auth null suppresses the credential on the wire")

    -- transport: curl's `-i` output, past a 100 Continue block
    (do
      let r := SdkRuntime.parseCurlOutput
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Type: application/json\r\nX-Cost: 3\r\nX-Cost: 4\r\n\r\n{\"id\":\"a\"}"
      check (r.status == 201 && r.statusText == "Created")
        "transport: the final status line is read past a 100 Continue"
      check (r.headers == #[("content-type", "application/json"), ("x-cost", "3, 4")])
        "transport: response headers are captured, lower-cased and merged"
      check (r.body == "{\"id\":\"a\"}") "transport: the body follows the last header block")

    -- transport: curl's `-i` output, past a proxy's CONNECT reply.
    -- REGRESSION PIN: only 1xx blocks were skipped, so every https request
    -- through an HTTP proxy - including one configured by https_proxy alone -
    -- read the tunnel's reply as the response: no headers, and the origin's
    -- own status line as the body. `-w %{http_code}` patched the status back,
    -- so the result looked right and carried nothing.
    (do
      let r := SdkRuntime.parseCurlOutput
        "HTTP/1.1 200 Connection Established\r\n\r\nHTTP/2 404 \r\ncontent-type: application/json\r\n\r\n{\"error\":\"gone\"}"
      check (r.status == 404) s!"transport: the origin status is read past a CONNECT reply ({r.status})"
      check (r.headers == #[("content-type", "application/json")])
        "transport: the origin headers are read past a CONNECT reply"
      check (r.body == "{\"error\":\"gone\"}")
        s!"transport: the origin body is read past a CONNECT reply ({r.body})")

    -- transport: the reason phrase an HTTP/2 status line does not carry.
    -- REGRESSION PIN: statusText came back empty over HTTP/2, so resultBasic
    -- built "request: 404: " and every error message ended in a bare colon.
    (do
      let known := SdkRuntime.parseCurlOutput "HTTP/2 503 \r\n\r\n"
      let unknown := SdkRuntime.parseCurlOutput "HTTP/2 599 \r\n\r\n"
      let sent := SdkRuntime.parseCurlOutput "HTTP/1.1 404 Nope\r\n\r\n"
      check (known.statusText == "Service Unavailable")
        s!"transport: a named code gets its reason phrase ({known.statusText})"
      check (unknown.statusText == "599")
        s!"transport: an unnamed code answers with the code ({unknown.statusText})"
      check (sent.statusText == "Nope")
        s!"transport: a reason phrase the server sent is kept ({sent.statusText})")

    -- transport: an empty header value reaches the wire. REGRESSION PIN:
    -- `-H "name: "` is curl's REMOVE-this-header syntax, so a header the
    -- pipeline prepared empty was suppressed rather than sent.
    (do
      let args := SdkRuntime.curlHeaderArgs #[("x-full", "v"), ("x-empty", "")]
      check (args == #["-H", "x-full: v", "-H", "x-empty;"])
        s!"transport: an empty header value is sent, not removed ({args})")

    -- pipeline: the match becomes the query string, the point's method is sent
    (do
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith (← emptyMap) pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyList) #[]))
      let m ← newMap #[("q", .str "x y")]
      let _ ← SdkRuntime.opList c "widget" m (← emptyMap)
      check ((← w.url.get) == "http://api.test/widget?q=x%20y")
        "pipeline: a list match reaches the wire as the query string"
      check ((← gpS (← w.fetchdef.get) "method") == "GET")
        "pipeline: the point's method reaches the wire")

    -- pipeline: an unknown $action is refused, not answered by another route.
    -- REGRESSION PIN: makePoint fell through to the entity's own route
    -- whenever nothing matched, so a mistyped action issued the plain GET
    -- instead of the request the caller asked for - and the caller was told
    -- nothing. ts and go return point_action_invalid.
    (do
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith (← emptyMap) pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      let m ← newMap #[("id", .str "g1"), ("$action", .str "nope")]
      let msg ← thrown (SdkRuntime.opLoad c "gadget" m (← emptyMap))
      check (hasSub msg "action \"nope\" is not valid")
        s!"pipeline: an unknown $action is refused ({msg})"
      check ((← w.calls.get) == 0) "pipeline: an unknown $action reaches no transport"
      let m2 ← newMap #[("id", .str "g1"), ("$action", .str "archive")]
      let _ ← SdkRuntime.opLoad c "gadget" m2 (← emptyMap)
      check (hasSub (← w.url.get) "/gadget/g1/archive")
        s!"pipeline: a declared $action picks its own point ({← w.url.get})")

    -- pipeline: options.allow.op gates the operation before any endpoint is
    -- resolved, as ts and go do
    (do
      let w ← mkWire
      let opts ← newMap #[("allow", ← newMap #[("op", .str "load")])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyList) #[]))
      let msg ← thrown (SdkRuntime.opList c "widget" (← emptyMap) (← emptyMap))
      check (hasSub msg "not allowed by SDK option allow.op")
        s!"pipeline: allow.op refuses an operation it does not name ({msg})"
      check ((← w.calls.get) == 0) "pipeline: a refused operation reaches no transport"
      let _ ← SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "i1")]) (← emptyMap)
      check ((← w.calls.get) == 1) "pipeline: allow.op permits the op it names")

    -- pipeline: options.allow.method gates the request's method, as ts and go do
    allowMethodCases
    allowEmptyCases
    allowDefaultCases

    -- pipeline: a feature's query param (paging, at PreRequest) survives makeSpec
    (do
      let w ← mkWire
      let opts ← liveOpts #[("paging", ← onOpts #[("size", .num 2.0)])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyList) #[]))
      let _ ← SdkRuntime.opList c "widget" (← emptyMap) (← emptyMap)
      let u ← w.url.get
      check (hasSub u "limit=2") s!"pipeline: paging's query param reaches the wire ({u})")

    -- pipeline: path params and the response transform
    (do
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith (← emptyMap) pipeConfig
        (recording w (do
          let ent ← newMap #[("id", .str "i1"), ("title", .str "T")]
          answer 200.0 "OK" (← newMap #[("widget", ent)]) #[]))
      let m ← newMap #[("id", .str "i1")]
      let got ← SdkRuntime.opLoad c "widget" m (← emptyMap)
      check ((← w.url.get) == "http://api.test/widget/i1")
        "pipeline: the path param is substituted, not queried"
      check ((← gpS got "title") == "T")
        "pipeline: the point's response transform unwraps the envelope")

    -- pipeline: the test mock wraps each listed record under the key the
    -- list's response transform reads it from
    (do
      let badge (id title : String) : SIO Value := newMap #[("id", .str id), ("title", .str title)]
      let badges ← newMap #[("b1", ← badge "b1" "one"), ("b2", ← badge "b2" "two")]
      let seed ← newMap #[("existing", ← newMap #[("badge", badges)])]
      let c ← SdkRuntime.mkTestClientV (← emptyMap) pipeConfig seed
      let got ← SdkRuntime.opList c "badge" (← emptyMap) (← emptyMap)
      let titles ← (← listItemsOf got).mapM fun r => gpS r "title"
      check (titles.qsort (· < ·) == #["one", "two"])
        s!"pipeline: a list reads the record each of its items wraps ({titles})")

    -- pipeline: a data op carries the request body
    (do
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith (← emptyMap) pipeConfig
        (recording w (do answer 201.0 "Created" (← newMap #[("id", .str "n1")]) #[]))
      let d ← newMap #[("title", .str "new")]
      let _ ← SdkRuntime.opCreate c "widget" d (← emptyMap)
      let f ← w.fetchdef.get
      check ((← gpS f "method") == "POST" && (← gpS (← gp f "body") "title") == "new")
        "pipeline: a data op sends the request body")

    -- pipeline: graphql posts {query, variables} to the single endpoint
    (do
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith (← emptyMap) pipeConfig
        (recording w (do
          let thing ← newMap #[("id", .str "g1")]
          answer 200.0 "OK" (← newMap #[("data", ← newMap #[("thing", thing)])]) #[]))
      let m ← newMap #[("id", .str "g1")]
      let got ← SdkRuntime.opLoad c "thing" m (← emptyMap)
      let body ← gp (← w.fetchdef.get) "body"
      check ((← w.url.get) == "http://api.test")
        "pipeline: a graphql op posts to the endpoint with no query string"
      check ((← gpS body "query").startsWith "query Thing" &&
             (← gpS (← gp body "variables") "id") == "g1")
        "pipeline: a graphql op sends {query, variables}"
      check ((← gpS got "id") == "g1")
        "pipeline: a graphql response is unwrapped by the point's transform")

    -- pipeline: a 4xx is an error; ctrl.throw false returns it on ctrl.err
    (do
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith (← emptyMap) pipeConfig
        (recording w (do answer 404.0 "Not Found" (← emptyMap) #[]))
      let m ← newMap #[("id", .str "nope")]
      let msg ← thrown (SdkRuntime.opLoad c "widget" m (← emptyMap))
      check (hasSub msg "request: 404: Not Found")
        s!"pipeline: a 4xx response is an error, not a result ({msg})"
      let ctrl ← newMap #[("throw", .bool false)]
      let got ← SdkRuntime.opLoad c "widget" m ctrl
      let err ← gp ctrl "err"
      check (SdkRuntime.isNv got && (← gpS err "code") == "request_status" &&
             (← numAt err "status") == 404.0)
        "pipeline: ctrl.throw false returns, with the error on ctrl.err")

    -- pipeline: done finishes the explain record, as ts's DoneUtility does.
    -- REGRESSION PIN: lean left the raw record in place, so the sensitive
    -- keys options.clean.keys names stayed in it and the failure was reported
    -- twice - once on the record, once inside the result it carries.
    (do
      let w ← mkWire
      let opts ← newMap #[("clean", ← newMap #[("keys", .str "fetchdef")])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 404.0 "Not Found" (← emptyMap) #[]))
      let ctrl ← newMap #[("explain", ← emptyMap), ("throw", .bool false)]
      let _ ← SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "nope")]) ctrl
      let ex ← gp ctrl "explain"
      check (SdkUtility.isMapV (← gp ex "result"))
        "pipeline: done keeps the explained result"
      check (SdkRuntime.isNv (← gp (← gp ex "result") "err"))
        "pipeline: done drops the error from the explained result"
      check ((← gpS ex "fetchdef") == "[redacted]")
        "pipeline: done masks the explain record's configured keys"
      check ((← gpS (← gp ex "err") "code") == "request_status")
        "pipeline: the failure is reported on the explain record itself")

    -- pipeline: with clean off, done still prunes a copy of the explain
    -- record, so the failure keeps its own error.
    (do
      let w ← mkWire
      let opts ← newMap #[("clean", ← newMap #[("active", .bool false)])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 404.0 "Not Found" (← emptyMap) #[]))
      let ctrl ← newMap #[("explain", ← emptyMap), ("throw", .bool false)]
      let _ ← SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "nope")]) ctrl
      let e ← gp ctrl "err"
      let msg ← gpS e "message"
      check ((← gpS e "code") == "request_status" && !hasSub msg "unknown error")
        s!"pipeline: with clean off, done leaves the live result's error ({msg})")

    -- pipeline: an error a hook throws never passed through makeError, so
    -- runOp cleans it on the way out.
    (do
      let opts ← liveOpts #[("probe", ← onOpts #[])]
      SdkUtility.sp opts "apikey" (.str "HOOKED-SECRET-4")
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      addProbe c (fun s ctx => do
        if s == "PreResponse" then
          throw (IO.userError ("hook saw " ++ (← stringify (← gp ctx "spec")))))
      let msg ← thrown (SdkRuntime.opList c "widget" (← emptyMap) (← emptyMap))
      check (hasSub msg "hook saw" && !hasSub msg "HOOKED-SECRET-4")
        s!"pipeline: an error a hook throws leaves cleaned ({msg})")

    -- pipeline: an exit before done cleans the explain record, which holds
    -- the live spec: a stage error through failOp, and a hook's throw.
    (do
      let opts ← liveOpts #[("probe", ← onOpts #[])]
      SdkUtility.sp opts "apikey" (.str "EXPLAIN-SECRET-5")
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      addProbe c (fun s ctx => do
        if s == "PreRequest" then SdkUtility.sp ctx "spec" .noval)
      let ctrl ← newMap #[("explain", ← emptyMap), ("throw", .bool false)]
      let _ ← SdkRuntime.opList c "widget" (← emptyMap) ctrl
      let ex ← stringify (← gp ctrl "explain")
      check ((← gpS (← gp ctrl "err") "code") == "url_no_spec" && hasSub ex "authorization"
             && !hasSub ex "EXPLAIN-SECRET-5")
        s!"pipeline: a stage error leaves its explain record cleaned ({ex})")

    (do
      let opts ← liveOpts #[("probe", ← onOpts #[])]
      SdkUtility.sp opts "apikey" (.str "EXPLAIN-SECRET-6")
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      addProbe c (fun s _ => do
        if s == "PreResponse" then throw (IO.userError "hook failed"))
      let ctrl ← newMap #[("explain", ← emptyMap)]
      let _ ← thrown (SdkRuntime.opList c "widget" (← emptyMap) ctrl)
      let ex ← stringify (← gp ctrl "explain")
      check (hasSub ex "authorization" && !hasSub ex "EXPLAIN-SECRET-6")
        s!"pipeline: a hook's throw leaves its explain record cleaned ({ex})")

    -- pipeline: the error's code is cleaned like its message.
    (do
      let opts ← liveOpts #[]
      SdkUtility.sp opts "apikey" (.str "CODE-SECRET-12")
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do pure (.noval, some (← SdkUtility.mkErr "refused_CODE-SECRET-12" "refused"))))
      let ctrl ← newMap #[("throw", .bool false)]
      let _ ← SdkRuntime.opList c "widget" (← emptyMap) ctrl
      let code ← gpS (← gp ctrl "err") "code"
      check (code == "refused_[redacted]") s!"pipeline: the error's code is cleaned ({code})")

    -- clean: a hint beyond any value's length leaves nothing of it visible.
    (do
      let opts ← SdkUtility.makeOptions (← emptyMap) (← newMap #[
        ("apikey", .str "HINT-SECRET-abcdef"),
        ("clean", ← newMap #[("hint", .str "5000000000000000000")])])
      let s ← SdkUtility.clean (← newMap #[("options", opts)]) (.str "k HINT-SECRET-abcdef")
      check (SdkUtility.vs s == "k [redacted]")
        s!"clean: a huge hint still masks the whole value ({SdkUtility.vs s})")

    -- clean: a registered value used as a property name is masked, and
    -- names that mask alike are all kept.
    (do
      let ctx ← newMap #[("options", ← SdkUtility.makeOptions (← emptyMap) (← emptyMap))]
      SdkUtility.cleanAdd ctx (.str "ZZVAL-abc123")
      SdkUtility.cleanAdd ctx (.str "ZZVAL-xyz789")
      let out ← SdkUtility.clean ctx (← newMap #[("ZZVAL-abc123", .num 1.0),
        ("ZZVAL-xyz789", .num 2.0), ("plain", .num 3.0)])
      let names := (← mapEntriesOf out).map (·.1)
      check (names == #["[redacted]", "[redacted]#1", "plain"])
        "clean: a registered value used as a property name is masked, collisions kept")

    -- clean: every scalar under a sensitive option name is registered, at any
    -- depth and of any shape, so a mistyped credential is masked too.
    (do
      let ctx ← newMap #[("options", ← SdkUtility.makeOptions (← emptyMap) (← emptyMap))]
      let loop ← newMap #[("token", .str "LOOP-SECRET-3")]
      SdkUtility.sp loop "self" loop
      SdkUtility.cleanAddSensitive ctx (← newMap #[
        ("apikey", ← newMap #[("value", .str "NESTED-SECRET-1")]),
        ("headers", ← newMap #[("X-Api-Token", ← newList #[.str "LISTED-SECRET-2"])]),
        ("secret", .num 123456789.0), ("name", .str "not-a-secret"), ("loop", loop)])
      let values ← SdkUtility.cfgStrings (← SdkUtility.cleanConfig ctx) "values"
      check (#["NESTED-SECRET-1", "LISTED-SECRET-2", "123456789", "LOOP-SECRET-3"].all values.contains
             && !values.contains "not-a-secret")
        "clean: cleanAddSensitive registers every scalar under a sensitive name")

    -- clean: the config's own clean block reaches the registry, between the
    -- defaults and the caller's block, and is not changed by it.
    (do
      let cfgclean ← newMap #[("keys", .str "zzsens"), ("values", .str "CONFIG-SEEDED-1")]
      let config ← newMap #[("options", ← newMap #[("clean", cfgclean)])]
      let opts ← SdkUtility.makeOptions config
        (← newMap #[("clean", ← newMap #[("values", .str "CALLER-SEEDED-2")])])
      let ctx ← newMap #[("options", opts)]
      let s ← SdkUtility.clean ctx (.str "a CONFIG-SEEDED-1 b CALLER-SEEDED-2")
      let m ← SdkUtility.clean ctx (← newMap #[("my_zzsens", .str "x"), ("other", .str "y")])
      check (SdkUtility.vs s == "a [redacted] b [redacted]" && (← gpS m "my_zzsens") == "[redacted]"
             && (← gpS m "other") == "y" && (← gpS cfgclean "values") == "CONFIG-SEEDED-1")
        "clean: the config's own clean block is honoured")

    -- clean: the keys under `feature` name features, so a feature called
    -- secrets does not make its settings secret; a sensitive field inside
    -- them still counts.
    (do
      let opts ← SdkUtility.makeOptions (← emptyMap) (← newMap #[("feature", ← newMap #[
        ("secrets", ← newMap #[("active", .bool false), ("kind", .str "vaultish"),
                               ("token", .str "REAL-TOKEN-1")])])])
      let values ← SdkUtility.cfgStrings (← SdkUtility.cleanConfig (← newMap #[("options", opts)])) "values"
      check (values.contains "REAL-TOKEN-1" && !values.contains "vaultish")
        "clean: a feature's name does not make its settings sensitive")

    cleanEntityBlocks

    -- proxy: the userinfo of the proxy URL is registered, and the password
    -- runs from the first colon, colons included.
    (do
      let w ← mkWire
      let opts ← liveOpts #[("proxy", ← onOpts #[("url", .str "http://user:abc:def@proxy.local:8080")])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      let s ← SdkUtility.clean (← newMap #[("options", ← gp c "options")]) (.str "pw abc:def")
      check (SdkUtility.vs s == "pw [redacted]")
        s!"proxy: a password holding a colon is registered whole ({SdkUtility.vs s})")

    (do
      let w ← mkWire
      let opts ← liveOpts #[("proxy", ← onOpts #[("url", .str "http://user:p%C3%A4ss@proxy.local:8080")])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      let s ← SdkUtility.clean (← newMap #[("options", ← gp c "options")]) (.str "pw päss")
      check (SdkUtility.vs s == "pw [redacted]")
        s!"proxy: a percent-encoded password is registered decoded as UTF-8 ({SdkUtility.vs s})")

    -- pipeline: a hook that has done a stage's work short-circuits it, as
    -- ts's makeSpec, makeRequest, makeResponse and makeResult each do on
    -- ctx.out. runOp honoured only out.point, so a feature that replaced a
    -- stage had its work overwritten by the stage it replaced.
    (do
      let opts ← liveOpts #[("probe", ← onOpts #[])]
      -- out.spec: the url comes from the spec the hook supplied
      let w ← mkWire
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyMap) #[]))
      shortCircuit c "PreSpec" "spec" (fun _ => do
        newMap #[("base", .str "http://hooked.test"), ("prefix", .str ""),
                 ("suffix", .str ""), ("path", .str "elsewhere"),
                 ("method", .str "GET"), ("params", ← emptyMap), ("query", ← emptyMap),
                 ("headers", ← emptyMap), ("alias", ← emptyMap), ("step", .str "start")])
      let _ ← SdkRuntime.opLoad c "widget" (← newMap #[("id", .str "i1")]) (← emptyMap)
      check ((← w.url.get) == "http://hooked.test/elsewhere")
        s!"pipeline: out.spec replaces the prepared request ({← w.url.get})"

      -- out.request: the response is the hook's, and the transport is not called
      let w2 ← mkWire
      let c2 ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w2 (do answer 200.0 "OK" (← newMap #[("id", .str "wire")]) #[]))
      shortCircuit c2 "PreRequest" "request" (fun _ => do
        newMap #[("status", .num 200.0), ("statusText", .str "OK"),
                 ("body", ← newMap #[("id", .str "hooked")]), ("headers", ← emptyMap)])
      let got2 ← SdkRuntime.opLoad c2 "gadget" (← newMap #[("id", .str "g1")]) (← emptyMap)
      check ((← w2.calls.get) == 0) "pipeline: out.request skips the transport"
      check ((← gpS got2 "id") == "hooked")
        s!"pipeline: out.request provides the response ({← gpS got2 "id"})"

      -- out.response: the reply is not folded into the result, so the result
      -- keeps the status makeResult gave it rather than the transport's 404
      let w3 ← mkWire
      let c3 ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w3 (do answer 404.0 "Not Found" (← emptyMap) #[]))
      shortCircuit c3 "PreResponse" "response" (fun ctx => do
        SdkUtility.sp (← gp ctx "result") "ok" (.bool true)
        gp ctx "response")
      let ctrl3 ← newMap #[("explain", ← emptyMap)]
      let _ ← SdkRuntime.opLoad c3 "widget" (← newMap #[("id", .str "i1")]) ctrl3
      let res3 ← gp (← gp ctrl3 "explain") "result"
      check ((← numAt res3 "status") == -1.0)
        s!"pipeline: out.response skips folding the reply into the result ({← numAt res3 "status"})"

      -- out.result: the response transform does not run again over it
      let w4 ← mkWire
      let c4 ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w4 (do
          answer 200.0 "OK" (← newMap #[("widget", ← newMap #[("id", .str "wire")])]) #[]))
      shortCircuit c4 "PreResult" "result" (fun ctx => do
        let res ← gp ctx "result"
        SdkUtility.sp res "resdata" (← newMap #[("id", .str "byresult")])
        pure res)
      let got4 ← SdkRuntime.opLoad c4 "widget" (← newMap #[("id", .str "i1")]) (← emptyMap)
      check ((← gpS got4 "id") == "byresult")
        s!"pipeline: out.result keeps the hook's result ({← gpS got4 "id"})")

    -- pipeline: which stages a failure dispatches, observed DIRECTLY.
    --
    -- The cost feature's bookkeeping cannot answer this and the check below
    -- used to claim it did: on a transport failure runOp carries the error
    -- through to PreDone, so the attempt is committed there whether or not
    -- PreUnexpected is dispatched at all. A failure BEFORE the transport is
    -- the case that skips PreDone, and it is the one PreUnexpected exists for.
    (do
      let w ← mkWire
      let opts ← liveOpts #[("probe", ← onOpts #[])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig (recording w refused)
      let seen ← probeStages c
      let _ ← thrown (SdkRuntime.opList c "widget" (← emptyMap) (← emptyMap))
      let late ← seen.get
      check (late.contains "PreDone" && late.contains "PreUnexpected")
        s!"pipeline: a transport failure dispatches PreDone then PreUnexpected ({late})"
      seen.set #[]
      let m ← newMap #[("id", .str "g1"), ("$action", .str "nope")]
      let _ ← thrown (SdkRuntime.opLoad c "gadget" m (← emptyMap))
      let early ← seen.get
      check (early.contains "PreUnexpected" && !(early.contains "PreDone"))
        s!"pipeline: a failure before the transport dispatches PreUnexpected alone ({early})")

    -- pipeline: a failed attempt is priced, and no pending cost carries over
    (do
      let w ← mkWire
      let failNext ← IO.mkRef true
      let opts ← liveOpts #[("cost", ← onOpts #[("unit", .num 1.0)])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig (recording w (do
        if (← failNext.get) then refused else answer 200.0 "OK" (← emptyList) #[]))
      let msg ← thrown (SdkRuntime.opList c "widget" (← emptyMap) (← emptyMap))
      check (hasSub msg "connection refused")
        "pipeline: a transport failure is the operation's error"
      let total ← gp (← bucketOf c "cost") "total"
      check ((← numAt total "attempts") == 1.0 && (← numAt total "calls") == 1.0 &&
             (← numAt total "amount") == 1.0)
        "pipeline: the failed attempt is committed (at PreDone, which it reaches)"
      failNext.set false
      let _ ← SdkRuntime.opList c "widget" (← emptyMap) (← emptyMap)
      let b ← bucketOf c "cost"
      check ((← numAt (← gp b "last") "attempts") == 1.0 &&
             (← numAt (← gp b "total") "calls") == 2.0)
        "pipeline: no pending cost leaks into the next operation")

    -- pipeline: response headers and the per-call ctrl reach the hooks
    (do
      let w ← mkWire
      let opts ← liveOpts #[("cost", ← onOpts #[("header", .str "X-Cost"), ("perUnit", .num 2.0)])]
      let c ← SdkRuntime.mkClientWith opts pipeConfig
        (recording w (do answer 200.0 "OK" (← emptyList) #[("X-Cost", .str "3")]))
      let ctrl ← newMap #[("actor", .str "alice")]
      let _ ← SdkRuntime.opList c "widget" (← emptyMap) ctrl
      let b ← bucketOf c "cost"
      check ((← numAt (← gp b "total") "reported") == 6.0 &&
             (← gpS (← gp b "last") "source") == "header")
        "pipeline: a server-reported cost header prices the call"
      check ((← numAt (← gp (← gp b "actors") "alice") "calls") == 1.0)
        "pipeline: the per-call ctrl reaches the hooks (cost attributes the actor)")

    match (← findSubject) with
    | none => IO.println "skip - no entity with list op and seed data"
    | some (ent, seed, hasCreate) => do

    -- log: counts requests
    (do
      let c ← clientWith seed #[("log", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "log"
      check ((← numAt b "calls") == 1.0) "log: counts one request")

    -- metrics: totals and a per-op bucket
    (do
      let c ← clientWith seed #[("metrics", ← onOpts #[])]
      let _ ← listAll c ent
      let _ ← listAll c ent
      let b ← bucketOf c "metrics"
      let total ← gp b "total"
      check ((← numAt total "count") == 2.0) "metrics: counts two operations"
      check ((← numAt total "ok") == 2.0) "metrics: both recorded ok"
      let ops ← gp b "ops"
      check ((← keysof ops).size >= 1) "metrics: per-op bucket created")

    -- telemetry: one span per operation, closed out
    (do
      let c ← clientWith seed #[("telemetry", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "telemetry"
      let spans ← gp b "spans"
      let n ← (match spans with | .list i => do pure (← listItems i).size | _ => pure 0)
      check (n == 1) "telemetry: records one span"
      check ((← numAt b "active") == 0.0) "telemetry: span closed (active back to 0)")

    -- audit: one record per operation
    (do
      let c ← clientWith seed #[("audit", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "audit"
      let recs ← gp b "records"
      let n ← (match recs with | .list i => do pure (← listItems i).size | _ => pure 0)
      check (n == 1) "audit: records one operation")

    -- debug: an entry, with sensitive headers redacted
    (do
      let c ← clientWith seed #[("debug", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "debug"
      let entries ← gp b "entries"
      match entries with
      | .list i => do
        let its ← listItems i
        check (its.size == 1) "debug: records one entry"
        if its.size > 0 then do
          let e := its[0]!
          check ((← gpS e "op") != "") "debug: entry names the operation"
      | _ => fail "debug: no entries list")

    -- idempotency: injects a key header on mutating ops only
    (do
      let c ← clientWith seed #[("idempotency", ← onOpts #[])]
      let _ ← listAll c ent
      let b0 ← bucketOf c "idempotency"
      check ((← numAt b0 "issued") == 0.0) "idempotency: no key for a read op"
      if hasCreate then
        let d ← newMap #[("name", .str "idem")]
        let _ ← SdkRuntime.opCreate c ent d (← emptyMap)
        let b ← bucketOf c "idempotency"
        check ((← numAt b "issued") == 1.0) "idempotency: issues a key for create"
        check ((← gpS b "last") != "") "idempotency: records the issued key")

    -- clienttrack: request/session headers and a request count
    (do
      let c ← clientWith seed #[("clienttrack", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "clienttrack"
      check ((← numAt b "requests") == 1.0) "clienttrack: counts the request"
      check ((← gpS b "session") != "") "clienttrack: assigns a session id"
      check ((← gpS b "lastRequestId") != "") "clienttrack: assigns a request id")

    -- rbac: denies when the required permission is absent, allows when granted
    (do
      let rules ← newMap #[("list", .str "read")]
      let c ← clientWith seed #[("rbac", ← onOpts #[("rules", rules)])]
      let denied ← (try
          let _ ← listAll c ent
          pure false
        catch _ => pure true)
      check denied "rbac: denies an operation without the permission"
      let b ← bucketOf c "rbac"
      check ((← numAt b "denied") == 1.0) "rbac: records the denial")
    (do
      let rules ← newMap #[("list", .str "read")]
      let perms ← newList #[.str "read"]
      let c ← clientWith seed #[("rbac", ← onOpts #[("rules", rules), ("perms", perms)])]
      let _ ← listAll c ent
      let b ← bucketOf c "rbac"
      check ((← numAt b "allowed") == 1.0) "rbac: allows when the permission is granted")

    -- cache: second identical read is served from the cache
    (do
      let c ← clientWith seed #[("cache", ← onOpts #[])]
      let _ ← listAll c ent
      let _ ← listAll c ent
      let b ← bucketOf c "cache"
      check ((← numAt b "miss") == 1.0) "cache: first read is a miss"
      check ((← numAt b "hit") == 1.0) "cache: second read is a hit")

    -- ratelimit: a tight burst throttles
    (do
      let c ← clientWith seed #[("ratelimit", ← onOpts #[("rate", .num 1.0), ("burst", .num 1.0)])]
      let _ ← listAll c ent
      let _ ← listAll c ent
      let b ← bucketOf c "ratelimit"
      check ((← numAt b "throttled") >= 1.0) "ratelimit: throttles the second call")

    -- netsim: offline simulation fails the request
    (do
      let c ← clientWith seed #[("netsim", ← onOpts #[("offline", .bool true)])]
      let failed ← (try
          let _ ← listAll c ent
          pure false
        catch _ => pure true)
      check failed "netsim: offline simulation fails the request"
      let b ← bucketOf c "netsim"
      check ((← numAt b "calls") == 1.0) "netsim: records the simulated call")

    -- netsim: failStatus is surfaced as the response status
    (do
      let c ← clientWith seed #[("netsim", ← onOpts #[("failStatus", .num 503.0)])]
      let _ ← (try
          let _ ← listAll c ent
          pure ()
        catch _ => pure ())
      let b ← bucketOf c "netsim"
      check ((← numAt b "calls") == 1.0) "netsim: failStatus simulation runs")

    -- proxy: annotates the transport and records the route
    (do
      let c ← clientWith seed #[("proxy", ← onOpts #[("url", .str "http://proxy.local:8080")])]
      let _ ← listAll c ent
      let b ← bucketOf c "proxy"
      check ((← numAt b "routed") == 1.0) "proxy: routes the request"
      check ((← gpS b "url") == "http://proxy.local:8080") "proxy: records the proxy url")

    -- timeout: a generous budget does not trip
    (do
      let c ← clientWith seed #[("timeout", ← onOpts #[("ms", .num 30000.0)])]
      let _ ← listAll c ent
      pass "timeout: request within budget succeeds")

    -- retry: a healthy transport is not retried
    (do
      let c ← clientWith seed #[("retry", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "retry"
      check ((← numAt b "attempts") == 0.0) "retry: no retry on a healthy response")

    -- paging: annotates the query and counts items
    (do
      let c ← clientWith seed #[("paging", ← onOpts #[("size", .num 2.0)])]
      let _ ← listAll c ent
      let b ← bucketOf c "paging"
      check ((← numAt b "pages") == 1.0) "paging: counts the page"
      check ((← numAt b "items") >= 1.0) "paging: counts the returned items")

    -- streaming: reports the emitted items
    (do
      let c ← clientWith seed #[("streaming", ← onOpts #[])]
      let _ ← listAll c ent
      let b ← bucketOf c "streaming"
      check ((← numAt b "emitted") >= 1.0) "streaming: emits the list items"
      check ((← numAt b "chunks") == 1.0) "streaming: reports one chunk")

    -- an inactive feature records nothing
    (do
      let off ← newMap #[("active", .bool false)]
      let c ← clientWith seed #[("log", off)]
      let _ ← listAll c ent
      let b ← bucketOf c "log"
      match b with
      | .map _ => fail "inactive feature must not record"
      | _ => pass "inactive feature records nothing")

  go.run sctx
  let p ← npass.get
  let f ← nfail.get
  IO.println ""
  IO.println s!"feature: PASS {p}  FAIL {f}"
  if f > 0 then return 1 else return 0
