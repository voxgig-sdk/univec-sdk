/- Univec SDK runtime: the generic, config-driven operation pipeline.

   Following the Haskell target's model, entities are NOT generated per-entity;
   the whole SDK is driven by the API model (a struct `Value` parsed from the
   embedded config). A client holds `options` + `config`; an operation runs
   the same stages as the ts reference, each through `SdkUtility`. The corpus
   pins those utilities one at a time and says nothing about this composition,
   which test/TFeature.lean pins over a recording transport:

     makeContext, PrePoint, makePoint, PreSpec, makeSpec, PreRequest,
     makeUrl + makeFetchDef + the transport, PreResponse, makeResponse,
     PreResult, transformResponse, PreDone, done (or the error exit, which
     dispatches PreUnexpected).

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
-- Transport: shell out to curl.
-- ---------------------------------------------------------------------------

structure CurlResponse where
  status : Nat
  statusText : String
  headers : Array (String × String)
  body : String
  deriving Inhabited

/-- One `Name: value` line, name lower-cased; a line without a colon is
    dropped. Splits at the FIRST colon: values carry colons (dates, urls). -/
def parseHeaderLine (line : String) : Option (String × String) :=
  match line.toList.span (· != ':') with
  | (name, ':' :: rest) =>
    some ((String.ofList name).trimAscii.toString.toLower, (String.ofList rest).trimAscii.toString)
  | _ => none

def addHeader (acc : Array (String × String)) (kv : String × String) : Array (String × String) :=
  match acc.findIdx? (·.1 == kv.1) with
  | some i => acc.modify i (fun (k, v) => (k, v ++ ", " ++ kv.2))
  | none => acc.push kv

/-- The reason phrase for a status code. HTTP/2 dropped it from the status
    line (`HTTP/2 404 `), so curl's `-i` output carries none and every error
    message derived from it ended in a bare colon. The common codes are named;
    anything else answers with the code, which still reads. -/
def reasonPhrase : Nat → String
  | 200 => "OK"
  | 201 => "Created"
  | 202 => "Accepted"
  | 204 => "No Content"
  | 301 => "Moved Permanently"
  | 302 => "Found"
  | 304 => "Not Modified"
  | 400 => "Bad Request"
  | 401 => "Unauthorized"
  | 403 => "Forbidden"
  | 404 => "Not Found"
  | 405 => "Method Not Allowed"
  | 409 => "Conflict"
  | 410 => "Gone"
  | 415 => "Unsupported Media Type"
  | 422 => "Unprocessable Content"
  | 429 => "Too Many Requests"
  | 500 => "Internal Server Error"
  | 501 => "Not Implemented"
  | 502 => "Bad Gateway"
  | 503 => "Service Unavailable"
  | 504 => "Gateway Timeout"
  | code => toString code

/-- A proxy's CONNECT reply. Tunnelling an https request through an HTTP
    proxy makes curl print the tunnel's own `200 Connection Established`
    block ahead of the origin server's response, so taking the first block
    yields no headers and a body of raw HTTP text — and `-w %{http_code}`
    hides it by patching the status back to the origin's. Only a block a
    real status line FOLLOWS is skipped, so an origin response that happens
    to carry this reason phrase is still read. -/
def connectReply (code : Nat) (reason rest : String) : Bool :=
  200 <= code && code < 300 && rest.startsWith "HTTP/" &&
  reason.trimAscii.toString.toLower.startsWith "connection established"

/-- Curl's `-i` output: the final header block gives statusText and headers,
    the rest is the body. Interim 1xx blocks (Expect: 100-continue) and a
    proxy's CONNECT reply precede the real one and are skipped. -/
partial def parseCurlOutput (raw : String) : CurlResponse :=
  if raw.startsWith "HTTP/" then
    let parts := raw.splitOn "\r\n\r\n"
    let block := parts.headD ""
    let rest := "\r\n\r\n".intercalate (parts.drop 1)
    let lines := block.splitOn "\r\n"
    let words := (lines.headD "").splitOn " "
    let code := (words[1]?.getD "").toNat?.getD 0
    let reason := (" ".intercalate (words.drop 2)).trimAscii.toString
    if (100 <= code && code < 200) || connectReply code reason rest then
      parseCurlOutput rest
    else
      { status := code
      , statusText := if reason == "" then reasonPhrase code else reason
      , headers := ((lines.drop 1).filterMap parseHeaderLine).foldl addHeader #[]
      , body := rest }
  else { status := 0, statusText := "", headers := #[], body := raw }

/-- One `-H` argument per header. `-H "name: "` is curl's syntax for REMOVING
    a header it would otherwise send, not for sending an empty one; the empty
    value takes the `-H "name;"` form instead. Without that an empty header the
    pipeline prepared never reached the wire, where in ts it does. -/
def curlHeaderArgs (headers : Array (String × String)) : Array String :=
  headers.foldl (fun acc kv =>
    acc ++ #["-H", if kv.2 == "" then kv.1 ++ ";" else kv.1 ++ ": " ++ kv.2]) #[]

/-- `headers` is every header the pipeline prepared (options.headers, the
    authorization header, whatever a feature added), each its own `-H`. -/
def curlFetch (method url : String) (headers : Array (String × String))
    (body : Option String) (timeoutSec : Float) (proxy : String) : IO CurlResponse := do
  let secs := if timeoutSec > 0.0 then timeoutSec else 20.0
  -- `--suppress-connect-headers` keeps a proxy's CONNECT reply out of the
  -- `-i` stream in the first place; parseCurlOutput skips one anyway, for the
  -- curl builds that do not honour it.
  let base := #["-s", "-S", "-i", "--suppress-connect-headers",
                "-w", "\n%{http_code}", "--max-time", numToString secs,
                "-X", method]
  let hasCT := headers.any (fun kv => kv.1.toLower == "content-type")
  let hdr := curlHeaderArgs headers
  let hdr := if body.isSome && !hasCT then hdr ++ #["-H", "Content-Type: application/json"] else hdr
  let dat := match body with | some b => #["--data-raw", b] | none => #[]
  let px := if proxy == "" then #[] else #["--proxy", proxy]
  let out ← IO.Process.output { cmd := "curl", args := base ++ hdr ++ dat ++ px ++ #[url] }
  if out.exitCode != 0 then
    throw (IO.userError s!"curl failed ({out.exitCode}): {out.stderr.trimAscii}")
  let lines := out.stdout.splitOn "\n"
  let status := (lines.getLastD "").toNat?.getD 0
  let parsed := parseCurlOutput (String.intercalate "\n" lines.dropLast)
  pure { parsed with status := if status > 0 then status else parsed.status }

/-- The fetchdef's header map as wire pairs (string and number values only). -/
def headerPairs (headersV : Value) : SIO (Array (String × String)) := do
  let mut headers : Array (String × String) := #[]
  match headersV with
  | .map _ =>
    for k in (← keysof headersV) do
      match (← gp headersV k) with
      | .str s => headers := headers.push (k, s)
      | .num n => headers := headers.push (k, numToString n)
      | _ => pure ()
  | _ => pure ()
  pure headers

/-- Several CDNs refuse a library's own agent, so a request without one
    carries the browser-shaped agent the other targets send. -/
def defaultUserAgent : String := "Mozilla/5.0 (compatible; UnivecSDK/1.0)"

/-- The pairs to send, with the default agent when the fetchdef names none,
    recorded with its headers so an error can name it. -/
def sentHeaders (fetchdef : Value) : SIO (Array (String × String)) := do
  let headers ← headerPairs (← gp fetchdef "headers")
  if headers.any (fun kv => kv.1.toLower == "user-agent") then return headers
  let hv ← gp fetchdef "headers"
  let hv ← if SdkUtility.isMapV hv then pure hv else do
    let m ← emptyMap
    SdkUtility.sp fetchdef "headers" m
    pure m
  SdkUtility.sp hv "user-agent" (.str defaultUserAgent)
  pure (headers.push ("user-agent", defaultUserAgent))

/-- A body that is neither blank nor one JSON value. -/
def bodyUnreadable (body : String) : Bool :=
  !(body.all Char.isWhitespace) && !(SdkJson.jsonValid body)

/-- Decode a readable body: as JSON when the server says so or it looks like
    JSON; a scalar sent as anything else stays text. -/
def readBody (headers : Value) (body : String) : SIO Value := do
  let ct := (asStr (← gp headers "content-type")).toLower
  let t := body.trimAscii.toString
  if t.isEmpty then pure .noval
  else if (ct.splitOn "json").length > 1 || t.startsWith "{" || t.startsWith "[" then
    SdkJson.jsonRead body
  else pure (.str body)

/-- The base transport: curl for a live client. `timeout` and `proxy` are
    the fetchdef fields the timeout and proxy features set. A failed curl is
    a transport error, not a thrown exception, so retry sees it. -/
def liveFetcher : SdkFeature.Fetcher := fun ctx url fetchdef => do
  let method := asStr (← gp fetchdef "method")
  let bodyStr ← SdkUtility.bodyText (← gp ctx "point") (← gp fetchdef "body")
  let headers ← sentHeaders fetchdef
  let timeout := match (← gp fetchdef "timeout") with | .num n => n | _ => 0.0
  let proxy ← gpS fetchdef "proxy"
  try
    let r ← curlFetch (if method == "" then "GET" else method) url headers bodyStr timeout proxy
    let hmap ← emptyMap
    for (k, v) in r.headers do
      SdkUtility.sp hmap k (.str v)
    -- A body that is not JSON is marked, and kept as its text for the error.
    let unreadable := bodyUnreadable r.body
    let bodyV ← if unreadable then pure (Value.str r.body) else readBody hmap r.body
    let resp ← newMap #[("status", .num r.status.toFloat), ("statusText", .str r.statusText),
                        ("body", bodyV), ("headers", hmap), ("unreadable", .bool unreadable)]
    pure (resp, none)
  catch e =>
    let resp ← newMap #[("status", .num (-1.0)), ("statusText", .str ""),
                        ("headers", ← emptyMap)]
    pure (resp, some (← SdkUtility.mkErr "request_transport" (toString e)))

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
  | "update" | "patch" => do
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

/-- The key a list's response transform
    ["`$EACH`", "body", {"`$MERGE`": "`.<key>`"}] reads each item's record
    under; empty for any other transform. -/
def itemEnvelopeKey (restf : Value) : SIO String := do
  let spec ← listItemsOf restf
  if spec.size != 3 || asStr spec[0]! != "`$EACH`" || asStr spec[1]! != "body" then pure ""
  else
    let merge := asStr (← gp spec[2]! "`$MERGE`")
    if merge.startsWith "`." && merge.endsWith "`" && merge.length > 3 then
      let key := ((merge.drop 2).dropEnd 1).toString
      if key.any (fun c => c == '.' || c == '`' || c == '$') then pure "" else pure key
    else pure ""

/-- THE MOCK HAS TO AGREE WITH THE MODEL. A point carrying
    `transform.res: `body.item`` describes an API that answers {"item": {...}}
    and the response transform unwraps that key on the way back. Returning the
    bare payload means the transform unwraps a property that is not there and
    the caller gets nothing. Mirrors the go/ts/lua/php mocks. -/
def mockEnvelope (ctx : Value) (data : Value) : SIO Value := do
  if isNv data then pure data else do
    let tm ← gp (← gp ctx "point") "transform"
    let restf ← gp tm "res"
    let key ← itemEnvelopeKey restf
    if !key.isEmpty && (match data with | .list _ => true | _ => false) then do
      let items ← listItemsOf data
      newList (← items.mapM fun item => newMap #[(key, item)])
    else do
      let spec := asStr restf
      -- Exactly `body.<key>`; a deeper path is not an envelope this mock can
      -- synthesise, so it is left alone rather than guessed at.
      if spec.startsWith "`body." && spec.endsWith "`" && spec.length > 7 then
        let inner := ((spec.drop 6).dropEnd 1).toString
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

-- ---------------------------------------------------------------------------
-- Feature wiring
--
-- The client carries: `featureopts` (name -> options), `features` (registry
-- indices, in add order) and `fetcher` (the head of the transport chain). Each
-- active feature's `init` wraps the current fetcher, so the LAST feature added
-- is outermost; the base of the chain is the mock (test mode) or curl (live).
-- ---------------------------------------------------------------------------

/-- Construct and initialise every configured feature for this client, over
    the given BASE transport (the innermost fetcher every feature wraps). -/
def initFeaturesWith (client : Value) (baseF : SdkFeature.Fetcher) : SIO Unit := do
  let fo ← resolveFeatureOpts client
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

/-- Construct and initialise every configured feature for this client: the
    base transport is the seeded store in test mode, curl otherwise. -/
def initFeatures (client : Value) : SIO Unit := do
  let baseF := if (← gpS client "mode") == "test" then testFetcher else liveFetcher
  initFeaturesWith client baseF

-- ---------------------------------------------------------------------------
-- The generic operation, with feature hooks at every pipeline stage.
-- ---------------------------------------------------------------------------

/-- The error exit shared by every stage: the shaped error is exposed on
    `ctrl.err` (the thrown IO error carries only its message), features see
    the failure through PreUnexpected, and the caller's `ctrl.throw: false`
    turns the throw into a plain return. -/
def failOp (client ctx : Value) (errv : Value) : SIO Value := do
  let result ← gp ctx "result"
  SdkUtility.sp result "ok" (.bool false)
  let e ← SdkUtility.makeError ctx errv
  let orig ← if (← SdkUtility.isErrV errv) then pure errv else gp result "err"
  let code ← gpS orig "code"
  if code != "" then SdkUtility.sp e "code" (← SdkUtility.clean ctx (.str code))
  SdkUtility.sp e "status" (← gp result "status")
  SdkUtility.sp e "result" (← SdkUtility.clean ctx result)
  SdkUtility.sp e "spec" (← SdkUtility.clean ctx (← gp ctx "spec"))
  let ctrl ← gp ctx "ctrl"
  SdkUtility.sp ctrl "err" e
  -- A stage error leaves before done, and the record holds the live spec.
  SdkUtility.doneExplain ctx
  let explain ← gp ctrl "explain"
  if SdkUtility.isMapV explain then SdkUtility.sp explain "err" e
  SdkFeature.dispatch client "PreUnexpected" ctx
  match (← getpropRaw ctrl "throw") with
  | .bool false => gp result "resdata"
  | _ => throw (IO.userError (← gpS e "message"))

/-- Run the transport chain. A returned or thrown error lands on
    `response.err`, so the result stages and every remaining hook still run
    and the failure is priced, logged and measured like any other. -/
def fetchResponse (fetch : SdkFeature.Fetcher) (ctx : Value) (url : String)
    (fetchdef : Value) : SIO Value := do
  let (resp, ferr) ← (try fetch ctx url fetchdef
    catch e => do pure (.noval, some (← SdkUtility.mkErr "request_fetch" (toString e))))
  let response ← match resp with
    | .map i => pure (Value.map i)
    | _ => newMap #[("status", .num (-1.0)), ("statusText", .str ""), ("headers", ← emptyMap)]
  if let some e := ferr then SdkUtility.sp response "err" e
  pure response

/-- A hook may have provided the stage's output on `ctx.out` already. -/
def hookOut (out : Value) (key : String) (make : SIO Value) : SIO Value := do
  let v ← gp out key
  if isNv v then make else pure v

def runOpStages (client : Value) (entityName opName : String)
    (matchV dataV callopts : Value) : SIO Value := do
  let options ← gp client "options"
  let config  ← gp client "config"
  let opcfg ← gp (← gp (← gp (← gp config "entity") entityName) "op") opName
  let op ← SdkUtility.operator (← newMap #[("entity", .str entityName), ("name", .str opName),
                                            ("input", .str (SdkUtility.opInputOf opName)),
                                            ("points", ← gp opcfg "points")])
  -- The caller's own map: `ctrl.err` is where a non-throwing failure is read.
  let ctrl ← SdkUtility.asMap callopts
  let reqmatch ← SdkUtility.asMap matchV
  let reqdata ← SdkUtility.asMap dataV
  let ctx ← SdkUtility.makeContext (← newMap #[
    ("client", client), ("options", options), ("config", config),
    ("opname", .str opName), ("op", op), ("ctrl", ctrl), ("out", ← emptyMap),
    ("reqmatch", reqmatch), ("reqdata", reqdata), ("match", reqmatch), ("data", reqdata)])
  let _ ← SdkUtility.makeResult ctx
  let out ← gp ctx "out"
  let explain ← gp ctrl "explain"

  SdkFeature.dispatch client "PrePoint" ctx
  let point ← hookOut out "point" (SdkUtility.makePoint ctx)
  if (← SdkUtility.isErrV point) then return (← failOp client ctx point)
  if isNv point then
    return (← failOp client ctx (← SdkUtility.mkErr "point_no_points"
      s!"Operation \"{opName}\" has no endpoint definitions."))
  SdkUtility.sp ctx "point" point

  -- Each stage below is skipped when the hook before it already did the
  -- stage's work, as the four ts stage utilities each are. `out.request`
  -- carries the RESPONSE, which is what ts's makeRequest returns: providing
  -- it stands in for the whole transport step, url and fetchdef included.
  SdkFeature.dispatch client "PreSpec" ctx
  let hookspec ← gp out "spec"
  if isNv hookspec then do
    let (_, serr) ← SdkUtility.makeSpec ctx
    if let some e := serr then return (← failOp client ctx e)
  else SdkUtility.sp ctx "spec" hookspec
  let spec ← gp ctx "spec"

  SdkFeature.dispatch client "PreRequest" ctx
  let mut response ← gp out "request"
  if isNv response then do
    let _ ← SdkUtility.makeRequest ctx
    let (urlV, uerr) ← SdkUtility.makeUrl ctx
    if let some e := uerr then return (← failOp client ctx e)
    let url := asStr urlV
    SdkUtility.sp spec "url" (.str url)
    let fetchdef ← SdkUtility.makeFetchDef ctx
    SdkUtility.sp fetchdef "url" (.str url)
    if SdkUtility.isMapV explain then SdkUtility.sp explain "fetchdef" fetchdef
    SdkUtility.sp spec "step" (.str "prerequest")
    response ← fetchResponse (← SdkFeature.getFetcher client) ctx url fetchdef
    SdkUtility.sp spec "step" (.str "postrequest")
  SdkUtility.sp ctx "response" response

  SdkFeature.dispatch client "PreResponse" ctx
  if isNv (← gp out "response") then
    discard <| SdkUtility.makeResponse ctx

  SdkFeature.dispatch client "PreResult" ctx
  if isNv (← gp out "result") then do
    SdkUtility.sp spec "step" (.str "result")
    discard <| SdkUtility.transformResponse ctx
  let result ← gp ctx "result"
  if SdkUtility.isMapV explain then SdkUtility.sp explain "result" result

  SdkFeature.dispatch client "PreDone" ctx
  SdkUtility.doneExplain ctx
  if SdkUtility.truthy (← gp result "ok") then gp result "resdata"
  else failOp client ctx .noval

/-- An error a hook threw never passed through makeError, so its message and
    the explain record are cleaned on the way out; failOp's are clean already. -/
def runOp (client : Value) (entityName opName : String)
    (matchV dataV callopts : Value) : SIO Value := do
  try
    runOpStages client entityName opName matchV dataV callopts
  catch e =>
    let ctx ← newMap #[("options", ← gp client "options"), ("ctrl", callopts)]
    SdkUtility.doneExplain ctx
    throw (IO.userError (SdkUtility.vs (← SdkUtility.clean ctx (.str (toString e)))))

-- Entity operation wrappers.
def opList   (c : Value) (e : String) (m co : Value) : SIO Value := do runOp c e "list"   m (← emptyMap) co
def opLoad   (c : Value) (e : String) (m co : Value) : SIO Value := do runOp c e "load"   m (← emptyMap) co
def opCreate (c : Value) (e : String) (d co : Value) : SIO Value := do runOp c e "create" (← emptyMap) d co
def opUpdate (c : Value) (e : String) (m d co : Value) : SIO Value := do runOp c e "update" m d co
def opPatch  (c : Value) (e : String) (m d co : Value) : SIO Value := do runOp c e "patch"  m d co
def opRemove (c : Value) (e : String) (m co : Value) : SIO Value := do runOp c e "remove" m (← emptyMap) co

/-- The client value: options resolved through makeOptions (defaults, then
    the model's config.options, then the caller's), as every other target
    does before its first operation. -/
def mkClientBase (options config : Value) (mode : String) : SIO Value := do
  let opts ← SdkUtility.makeOptions config options
  newMap #[("options", opts), ("config", config), ("mode", .str mode)]

/-- Build a client Value from options + config JSON strings. -/
def mkClient (optionsJson configJson : String) : SIO Value := do
  let c ← mkClientBase (← SdkJson.jsonRead optionsJson) (← SdkJson.jsonRead configJson) "live"
  initFeatures c
  pure c

/-- Build a client from an options `Value` (the generated `newSdk` entry). -/
def mkClientV (options : Value) (configJson : String) : SIO Value := do
  let c ← mkClientBase options (← SdkJson.jsonRead configJson) "live"
  initFeatures c
  pure c

/-- A LIVE-mode client over a caller-supplied base transport.

    The lean spelling of the `options.utility.fetcher` seam every dynamically
    typed target honours: a struct `Value` cannot carry a closure, so the
    transport is a constructor argument instead of an option. Every feature
    wraps `base` exactly as it wraps curl, which is what lets a shipped test
    drive a live client and count what reaches the wire. -/
def mkClientWith (options : Value) (configJson : String) (base : SdkFeature.Fetcher)
    : SIO Value := do
  let c ← mkClientBase options (← SdkJson.jsonRead configJson) "live"
  initFeaturesWith c base
  pure c

/-- A test-mode client: operations are answered from an in-memory store seeded
    with the entity test data, so entity behaviour is verifiable offline. -/
def mkTestClientV (options : Value) (configJson : String) (seed : Value) : SIO Value := do
  let c ← mkClientBase options (← SdkJson.jsonRead configJson) "test"
  let existing ← gp seed "existing"
  let store ← (match existing with
    | .map _ => clone existing
    | _ => emptyMap)
  SdkUtility.sp c "store" store
  initFeatures c
  pure c

end SdkRuntime
