/- Univec SDK runtime: the generic, config-driven operation pipeline.

   Following the Haskell target's model, entities are NOT generated per-entity;
   the whole SDK is driven by the API model (a struct `Value` parsed from the
   embedded config). A client holds `options` + `config`; an operation looks up
   `config.entity.<name>.op.<op>.points`, selects the matching endpoint, builds
   the URL/method/body, calls the `curl` transport, parses the JSON response,
   and applies the response transform.

   The struct `Value` is the single data model throughout (like map[string]any
   in the Go/Python SDKs); everything runs in struct's `SIO` monad. -/

import VoxgigStruct
import SdkJson
import SdkUtility
import SdkFeature
import SdkFeatures

open VoxgigStruct

namespace SdkRuntime

/-- Pure string view of a scalar Value. -/
def asStr : Value → String
  | .str s => s
  | _ => ""

def isNv : Value → Bool
  | .noval => true
  | .null  => true
  | _      => false

/-- Get a map field by string key (noval if absent). -/
def gp (v : Value) (k : String) : SIO Value := getprop v (.str k) .noval

def gpS (v : Value) (k : String) : SIO String := do pure (asStr (← gp v k))

-- ---------------------------------------------------------------------------
-- Transport: shell out to curl. Returns (status, body).
-- ---------------------------------------------------------------------------

def curlFetch (method url : String) (body : Option String) : IO (Nat × String) := do
  let base := #["-s", "-w", "\n%{http_code}", "--max-time", "20", "-X", method]
  let hdr  := if body.isSome then #["-H", "Content-Type: application/json"] else #[]
  let dat  := match body with | some b => #["-d", b] | none => #[]
  let out ← IO.Process.output { cmd := "curl", args := base ++ hdr ++ dat ++ #[url] }
  if out.exitCode != 0 then
    throw (IO.userError s!"curl failed ({out.exitCode}): {out.stderr}")
  let lines := out.stdout.splitOn "\n"
  let status := (lines.getLastD "0").toNat!
  let bodyStr := String.intercalate "\n" lines.dropLast
  return (status, bodyStr)

-- ---------------------------------------------------------------------------
-- Point selection (mirrors SdkRuntime.hs prepareOperation): all select.exist
-- keys must be present in match/data, and select.$action must equal the
-- caller's $action (both absent = the plain point).
-- ---------------------------------------------------------------------------

def existOk (point matchV dataV : Value) : SIO Bool := do
  let sel ← gp point "select"
  match (← gp sel "exist") with
  | .list id => do
    let mut ok := true
    for ek in (← listItems id) do
      let k := asStr ek
      if isNv (← gp matchV k) && isNv (← gp dataV k) then ok := false
    pure ok
  | _ => pure true

def actionOk (point matchV : Value) : SIO Bool := do
  let sel ← gp point "select"
  pure ((← gp sel "$action") == (← gp matchV "$action"))

def selectPoint (points matchV dataV : Value) : SIO Value := do
  match points with
  | .list id => do
    let pts ← listItems id
    if pts.size == 1 then pure pts[0]!
    else do
      for pt in pts do
        if (← existOk pt matchV dataV) && (← actionOk pt matchV) then return pt
      pure .noval
  | _ => pure .noval

-- ---------------------------------------------------------------------------
-- Request building + response transform.
-- ---------------------------------------------------------------------------

/-- Substitute a `{name}` path segment from match (falling back to data). -/
def resolvePart (seg : String) (matchV dataV : Value) : SIO String := do
  if seg.startsWith "{" && seg.endsWith "}" then
    let key := (seg.replace "{" "").replace "}" ""
    let mv ← gp matchV key
    let v ← if isNv mv then gp dataV key else pure mv
    pure (asStr v)
  else pure seg

def buildUrl (base : String) (point matchV dataV : Value) : SIO String := do
  match (← gp point "parts") with
  | .list id => do
    let mut segs : Array String := #[]
    for p in (← listItems id) do
      segs := segs.push (← resolvePart (asStr p) matchV dataV)
    pure (base ++ "/" ++ String.intercalate "/" segs.toList)
  | _ => pure base

/-- Strip surrounding backticks from a transform expression. -/
def unquote (s : String) : String := s.replace "`" ""

/-- Apply transform.res: `body`, `body.entity`, etc. -/
def resTransform (point body : Value) : SIO Value := do
  let tr ← gp point "transform"
  let e := unquote (← gpS tr "res")
  let segs := e.splitOn "."
  let mut cur := body
  for s in segs.drop 1 do
    cur ← gp cur s
  pure cur

-- ---------------------------------------------------------------------------
-- Test mode: an in-memory mock transport.
--
-- The `test` feature of the other targets seeds an entity store and answers
-- operations from it, so entity behaviour is verifiable with no server. The
-- store is `client.store.<entity>` : a map of id -> entity.
-- ---------------------------------------------------------------------------

/-- Every field of `matchV` must equal the entity's field. -/
def entMatches (ent matchV : Value) : SIO Bool := do
  match matchV with
  | .map i => do
    let mut ok := true
    for k in (← keysof (.map i)) do
      let want ← gp (.map i) k
      if !(isNv want) then
        if !((← gp ent k) == want) then ok := false
    pure ok
  | _ => pure true

/-- Deterministic id for created entities (no clock/RNG in Lean). -/
def nextTestId (store : Value) : SIO String := do
  let n ← gp store "__seq__"
  let i := (match n with | .num f => f | _ => 0.0) + 1.0
  let _ ← setprop store (.str "__seq__") (.num i)
  pure ("t" ++ numToString i)

def mockOp (client : Value) (entityName opName : String)
    (matchV dataV : Value) : SIO Value := do
  let store ← gp client "store"
  let entmap ← (match (← gp store entityName) with
    | .map i => pure (Value.map i)
    | _ => do let m ← emptyMap; let _ ← setprop store (.str entityName) m; pure m)
  let idOf (v : Value) : SIO String := do pure (asStr (← gp v "id"))
  match opName with
  | "list" => do
    let mut out : Array Value := #[]
    for k in (← keysof entmap) do
      let e ← gp entmap k
      if (← entMatches e matchV) then out := out.push e
    newList out
  | "load" => do
    let wid ← idOf matchV
    pure ((← gp entmap wid))
  | "remove" => do
    let wid ← idOf matchV
    let _ ← delprop entmap (.str wid)
    emptyMap
  | "create" => do
    let ent ← clone dataV
    let given ← idOf dataV
    let eid ← if given != "" then pure given else nextTestId store
    let _ ← setprop ent (.str "id") (.str eid)
    let _ ← setprop entmap (.str eid) ent
    pure ent
  | "update" => do
    let wid0 ← idOf dataV
    let wid ← if wid0 != "" then pure wid0 else idOf matchV
    let cur ← gp entmap wid
    match cur with
    | .map _ => do
      for k in (← keysof dataV) do
        let _ ← setprop cur (.str k) (← gp dataV k)
      pure cur
    | _ => emptyMap
  | _ => emptyMap

-- ---------------------------------------------------------------------------
-- Feature wiring
--
-- The client carries: `featureopts` (name -> options), `features` (registry
-- indices, in add order) and `fetcher` (the head of the transport chain). Each
-- active feature's `init` wraps the current fetcher, so the LAST feature added
-- is outermost; the base of the chain is the mock (test mode) or curl (live).
-- ---------------------------------------------------------------------------

/-- The base transport: curl for a live client. -/
def liveFetcher : SdkFeature.Fetcher := fun _ctx url fetchdef => do
  let method := asStr (← gp fetchdef "method")
  let bodyV ← gp fetchdef "body"
  let bodyStr ← if isNv bodyV then pure none else (do pure (some (← jsonify bodyV)))
  let (st, respBody) ← curlFetch (if method == "" then "GET" else method) url bodyStr
  let json ← SdkJson.jsonRead respBody
  let resp ← newMap #[("status", .num st.toFloat), ("statusText", .str "OK"),
                      ("body", json), ("headers", ← emptyMap)]
  pure (resp, none)

/-- THE MOCK HAS TO AGREE WITH THE MODEL. A point carrying
    `transform.res: `body.item`` describes an API that answers {"item": {...}}
    and the response transform unwraps that key on the way back. Returning the
    bare payload means the transform unwraps a property that is not there and
    the caller gets nothing. Mirrors the go/ts/lua/php mocks. -/
def mockEnvelope (ctx : Value) (data : Value) : SIO Value := do
  if isNv data then pure data else do
    let tm ← gp (← gp ctx "point") "transform"
    let spec := asStr (← gp tm "res")
    -- Exactly `body.<key>`; a deeper path is not an envelope this mock can
    -- synthesise, so it is left alone rather than guessed at.
    if spec.startsWith "`body." && spec.endsWith "`" && spec.length > 7 then
      let inner := ((spec.drop 6).dropRight 1).toString
      if inner.isEmpty || inner.contains '.' then pure data
      else newMap #[(inner, data)]
    else pure data

/-- The base transport in test mode: answer from the seeded store. -/
def testFetcher : SdkFeature.Fetcher := fun ctx _url _fetchdef => do
  let client ← gp ctx "client"
  let entityName ← gpS (← gp ctx "op") "entity"
  let opName ← gpS (← gp ctx "op") "name"
  let matchV ← gp ctx "reqmatch"
  let dataV ← gp ctx "reqdata"
  let out ← mockOp client entityName opName matchV dataV
  let payload ← mockEnvelope ctx out
  let resp ← newMap #[("status", .num 200.0), ("statusText", .str "OK"),
                      ("body", payload), ("headers", ← emptyMap)]
  pure (resp, none)

/-- Merge config.feature and options.feature into the client's feature options. -/
def resolveFeatureOpts (client : Value) : SIO Value := do
  let config ← gp client "config"
  let options ← gp client "options"
  let cf ← (match (← gp config "feature") with | .map i => pure (Value.map i) | _ => emptyMap)
  let of0 ← (match (← gp options "feature") with | .map i => pure (Value.map i) | _ => emptyMap)
  let merged ← merge (← newList #[cf, of0])
  let fo ← (match merged with | .map i => pure (Value.map i) | _ => emptyMap)
  SdkUtility.sp client "featureopts" fo
  pure fo

/-- Construct and initialise every configured feature for this client. -/
def initFeatures (client : Value) : SIO Unit := do
  let fo ← resolveFeatureOpts client
  let baseF := if (← gpS client "mode") == "test" then testFetcher else liveFetcher
  SdkFeature.setFetcher client baseF
  let ctx ← newMap #[("client", client)]
  let mut ids : Array Value := #[]
  for name in SdkFeatures.featureNames do
    let opts ← gp fo name
    if (← SdkFeature.optActive opts) then do
      let f ← SdkFeatures.makeFeature name
      let id ← SdkFeature.registerFeature f
      ids := ids.push (.num id.toFloat)
      f.init ctx opts
  SdkUtility.sp client "features" (← newList ids)

-- ---------------------------------------------------------------------------
-- The generic operation, with feature hooks at every pipeline stage.
-- ---------------------------------------------------------------------------

def runOp (client : Value) (entityName opName : String)
    (matchV dataV _callopts : Value) : SIO Value := do
  let options ← gp client "options"
  let config  ← gp client "config"
  let op ← newMap #[("name", .str opName), ("entity", .str entityName),
                    ("input", .str (SdkUtility.opInputOf opName))]
  let out ← emptyMap
  let ctx ← newMap #[("client", client), ("options", options), ("config", config),
                     ("opname", .str opName), ("op", op), ("out", out),
                     ("reqmatch", matchV), ("reqdata", dataV),
                     ("match", matchV), ("data", dataV)]
  let _ ← SdkUtility.makeResult ctx

  -- PrePoint: a feature may short-circuit here (rbac denies by setting out.point).
  SdkFeature.dispatch client "PrePoint" ctx
  let denied ← gp out "point"
  if (← SdkUtility.isErrV denied) then
    throw (IO.userError (← gpS denied "message"))

  let ent ← gp (← gp config "entity") entityName
  let opcfg ← gp (← gp ent "op") opName
  let point ← selectPoint (← gp opcfg "points") matchV dataV
  if isNv point then
    throw (IO.userError s!"Operation \"{opName}\" has no matching endpoint for {entityName}.")
  SdkUtility.sp ctx "point" point

  -- PreSpec: build the request description.
  let userBase ← gpS options "base"
  let base ← if userBase != "" then pure userBase
             else gpS (← gp config "options") "base"
  let url ← buildUrl base point matchV dataV
  let method ← gpS point "method"
  let headers ← SdkUtility.prepareHeaders ctx
  let spec ← newMap #[("base", .str base), ("method", .str method),
                      ("headers", headers), ("step", .str "start")]
  SdkUtility.sp ctx "spec" spec
  SdkUtility.sp spec "query" (← emptyMap)
  SdkFeature.dispatch client "PreSpec" ctx

  let hasBody := method == "POST" || method == "PUT" || method == "PATCH"
  if hasBody then SdkUtility.sp spec "body" dataV

  -- PreRequest: last chance to alter headers/transport (idempotency, clienttrack).
  SdkFeature.dispatch client "PreRequest" ctx

  let fetchdef ← SdkUtility.makeFetchDef ctx
  let fetch ← SdkFeature.getFetcher client
  let (resp, ferr) ← fetch ctx url fetchdef
  match ferr with
  | some e => throw (IO.userError (← gpS e "message"))
  | none => pure ()
  SdkUtility.sp ctx "response" resp

  -- PreResponse / PreResult: fold the response into the result.
  SdkFeature.dispatch client "PreResponse" ctx
  let body ← gp resp "body"
  let resdata ← resTransform point body
  let result ← gp ctx "result"
  SdkUtility.sp result "body" body
  SdkUtility.sp result "resdata" resdata
  SdkUtility.sp result "status" (← gp resp "status")
  SdkUtility.sp result "ok" (.bool true)
  SdkFeature.dispatch client "PreResult" ctx

  -- PreDone: metrics/telemetry/audit close out here.
  SdkFeature.dispatch client "PreDone" ctx
  pure resdata

-- Entity operation wrappers.
def opList   (c : Value) (e : String) (m co : Value) : SIO Value := do runOp c e "list"   m (← emptyMap) co
def opLoad   (c : Value) (e : String) (m co : Value) : SIO Value := do runOp c e "load"   m (← emptyMap) co
def opCreate (c : Value) (e : String) (d co : Value) : SIO Value := do runOp c e "create" (← emptyMap) d co
def opUpdate (c : Value) (e : String) (m d co : Value) : SIO Value := do runOp c e "update" m d co
def opRemove (c : Value) (e : String) (m co : Value) : SIO Value := do runOp c e "remove" m (← emptyMap) co

/-- Build a client Value from options + config JSON strings. -/
def mkClient (optionsJson configJson : String) : SIO Value := do
  let options ← SdkJson.jsonRead optionsJson
  let config  ← SdkJson.jsonRead configJson
  let c ← newMap #[("options", options), ("config", config), ("mode", .str "live")]
  initFeatures c
  pure c

/-- Build a client from an options `Value` (the generated `newSdk` entry). -/
def mkClientV (options : Value) (configJson : String) : SIO Value := do
  let opts ← (match options with | .map _ => pure options | _ => emptyMap)
  let config ← SdkJson.jsonRead configJson
  let c ← newMap #[("options", opts), ("config", config), ("mode", .str "live")]
  initFeatures c
  pure c

/-- A test-mode client: operations are answered from an in-memory store seeded
    with the entity test data, so entity behaviour is verifiable offline. -/
def mkTestClientV (options : Value) (configJson : String) (seed : Value) : SIO Value := do
  let opts ← (match options with | .map _ => pure options | _ => emptyMap)
  let config ← SdkJson.jsonRead configJson
  let existing ← gp seed "existing"
  let store ← (match existing with
    | .map _ => clone existing
    | _ => emptyMap)
  let c ← newMap #[("options", opts), ("config", config), ("mode", .str "test"),
                   ("store", store)]
  initFeatures c
  pure c

end SdkRuntime
