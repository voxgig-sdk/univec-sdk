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
        let mt ← emptyMap
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
        let _ ← SdkRuntime.opList c ent mt mt
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
        let _ ← SdkRuntime.opList c2 ent mt mt
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
      check (SdkRuntime.isNv (← gp ex "fetchdef"))
        "pipeline: done cleans the explain record of the configured keys"
      check ((← gpS (← gp ex "err") "code") == "request_status")
        "pipeline: the failure is reported on the explain record itself")

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
    let mt ← emptyMap

    -- log: counts requests
    (do
      let c ← clientWith seed #[("log", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "log"
      check ((← numAt b "calls") == 1.0) "log: counts one request")

    -- metrics: totals and a per-op bucket
    (do
      let c ← clientWith seed #[("metrics", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "metrics"
      let total ← gp b "total"
      check ((← numAt total "count") == 2.0) "metrics: counts two operations"
      check ((← numAt total "ok") == 2.0) "metrics: both recorded ok"
      let ops ← gp b "ops"
      check ((← keysof ops).size >= 1) "metrics: per-op bucket created")

    -- telemetry: one span per operation, closed out
    (do
      let c ← clientWith seed #[("telemetry", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "telemetry"
      let spans ← gp b "spans"
      let n ← (match spans with | .list i => do pure (← listItems i).size | _ => pure 0)
      check (n == 1) "telemetry: records one span"
      check ((← numAt b "active") == 0.0) "telemetry: span closed (active back to 0)")

    -- audit: one record per operation
    (do
      let c ← clientWith seed #[("audit", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "audit"
      let recs ← gp b "records"
      let n ← (match recs with | .list i => do pure (← listItems i).size | _ => pure 0)
      check (n == 1) "audit: records one operation")

    -- debug: an entry, with sensitive headers redacted
    (do
      let c ← clientWith seed #[("debug", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
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
      let _ ← SdkRuntime.opList c ent mt mt
      let b0 ← bucketOf c "idempotency"
      check ((← numAt b0 "issued") == 0.0) "idempotency: no key for a read op"
      if hasCreate then
        let d ← newMap #[("name", .str "idem")]
        let _ ← SdkRuntime.opCreate c ent d mt
        let b ← bucketOf c "idempotency"
        check ((← numAt b "issued") == 1.0) "idempotency: issues a key for create"
        check ((← gpS b "last") != "") "idempotency: records the issued key")

    -- clienttrack: request/session headers and a request count
    (do
      let c ← clientWith seed #[("clienttrack", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "clienttrack"
      check ((← numAt b "requests") == 1.0) "clienttrack: counts the request"
      check ((← gpS b "session") != "") "clienttrack: assigns a session id"
      check ((← gpS b "lastRequestId") != "") "clienttrack: assigns a request id")

    -- rbac: denies when the required permission is absent, allows when granted
    (do
      let rules ← newMap #[("list", .str "read")]
      let c ← clientWith seed #[("rbac", ← onOpts #[("rules", rules)])]
      let denied ← (try
          let _ ← SdkRuntime.opList c ent mt mt
          pure false
        catch _ => pure true)
      check denied "rbac: denies an operation without the permission"
      let b ← bucketOf c "rbac"
      check ((← numAt b "denied") == 1.0) "rbac: records the denial")
    (do
      let rules ← newMap #[("list", .str "read")]
      let perms ← newList #[.str "read"]
      let c ← clientWith seed #[("rbac", ← onOpts #[("rules", rules), ("perms", perms)])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "rbac"
      check ((← numAt b "allowed") == 1.0) "rbac: allows when the permission is granted")

    -- cache: second identical read is served from the cache
    (do
      let c ← clientWith seed #[("cache", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "cache"
      check ((← numAt b "miss") == 1.0) "cache: first read is a miss"
      check ((← numAt b "hit") == 1.0) "cache: second read is a hit")

    -- ratelimit: a tight burst throttles
    (do
      let c ← clientWith seed #[("ratelimit", ← onOpts #[("rate", .num 1.0), ("burst", .num 1.0)])]
      let _ ← SdkRuntime.opList c ent mt mt
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "ratelimit"
      check ((← numAt b "throttled") >= 1.0) "ratelimit: throttles the second call")

    -- netsim: offline simulation fails the request
    (do
      let c ← clientWith seed #[("netsim", ← onOpts #[("offline", .bool true)])]
      let failed ← (try
          let _ ← SdkRuntime.opList c ent mt mt
          pure false
        catch _ => pure true)
      check failed "netsim: offline simulation fails the request"
      let b ← bucketOf c "netsim"
      check ((← numAt b "calls") == 1.0) "netsim: records the simulated call")

    -- netsim: failStatus is surfaced as the response status
    (do
      let c ← clientWith seed #[("netsim", ← onOpts #[("failStatus", .num 503.0)])]
      let _ ← (try
          let _ ← SdkRuntime.opList c ent mt mt
          pure ()
        catch _ => pure ())
      let b ← bucketOf c "netsim"
      check ((← numAt b "calls") == 1.0) "netsim: failStatus simulation runs")

    -- proxy: annotates the transport and records the route
    (do
      let c ← clientWith seed #[("proxy", ← onOpts #[("url", .str "http://proxy.local:8080")])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "proxy"
      check ((← numAt b "routed") == 1.0) "proxy: routes the request"
      check ((← gpS b "url") == "http://proxy.local:8080") "proxy: records the proxy url")

    -- timeout: a generous budget does not trip
    (do
      let c ← clientWith seed #[("timeout", ← onOpts #[("ms", .num 30000.0)])]
      let _ ← SdkRuntime.opList c ent mt mt
      pass "timeout: request within budget succeeds")

    -- retry: a healthy transport is not retried
    (do
      let c ← clientWith seed #[("retry", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "retry"
      check ((← numAt b "attempts") == 0.0) "retry: no retry on a healthy response")

    -- paging: annotates the query and counts items
    (do
      let c ← clientWith seed #[("paging", ← onOpts #[("size", .num 2.0)])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "paging"
      check ((← numAt b "pages") == 1.0) "paging: counts the page"
      check ((← numAt b "items") >= 1.0) "paging: counts the returned items")

    -- streaming: reports the emitted items
    (do
      let c ← clientWith seed #[("streaming", ← onOpts #[])]
      let _ ← SdkRuntime.opList c ent mt mt
      let b ← bucketOf c "streaming"
      check ((← numAt b "emitted") >= 1.0) "streaming: emits the list items"
      check ((← numAt b "chunks") == 1.0) "streaming: reports one chunk")

    -- an inactive feature records nothing
    (do
      let off ← newMap #[("active", .bool false)]
      let c ← clientWith seed #[("log", off)]
      let _ ← SdkRuntime.opList c ent mt mt
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
