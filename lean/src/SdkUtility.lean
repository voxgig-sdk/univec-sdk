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
  | _        => "match"

/-- The operation name: `ctx.opname`, falling back to `ctx.op.name`. -/
def opnameOf (ctx : Value) : SIO String := do
  let n ← gpS ctx "opname"
  if n != "" then pure n
  else do gpS (← gp ctx "op") "name"

-- ---------------------------------------------------------------------------
-- makeOptions / makeContext / operator / makeError / done
-- ---------------------------------------------------------------------------

def defaultOptions : SIO Value := do
  let hdr ← newMap #[("content-type", .str "application/json")]
  let ent ← emptyMap
  newMap #[("base", .str "http://localhost:8000"), ("prefix", .str ""),
           ("suffix", .str ""), ("headers", hdr), ("entity", ent)]

/-- Defaults <- config.options <- options, then every entity gets an alias map. -/
def makeOptions (config options : Value) : SIO Value := do
  let base ← defaultOptions
  let copts ← asMap (← gp config "options")
  let uopts ← asMap options
  let parts ← newList #[base, copts, uopts]
  let out ← merge parts
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
  mkErr "sdk_error" (nm ++ "SDK: " ++ opname ++ ": " ++ msg)

/-- Terminal step: the result payload, or the pipeline error. -/
def done (ctx : Value) : SIO (Value × Option Value) := do
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

/-- Everything in reqmatch that is NOT a declared path param becomes query. -/
def prepareQuery (ctx : Value) : SIO Value := do
  let point ← gp ctx "point"
  let reqmatch ← asMap (← gp ctx "reqmatch")
  let names ← match (← gp point "params") with
    | .list i => do pure ((← listItems i).map vs)
    | _ => pure #[]
  let out ← emptyMap
  for k in (← keysof reqmatch) do
    let v ← gp reqmatch k
    if !(isNov v) && !(names.contains k) then sp out k v
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

def prepareHeaders (ctx : Value) : SIO Value := do
  let options ← gp ctx "options"
  match (← gp options "headers") with
  | .map i => clone (.map i)
  | _ => newMap #[("content-type", .str "application/json")]

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
      let pfx ← gpS (← gp options "auth") "prefix"
      let authval := if pfx != "" then pfx ++ " " ++ apikey else apikey
      sp headers "authorization" (.str authval)
      pure (specV, none)
  | _ => do
    let e ← mkErr "auth_no_spec" "Expected context spec property to be defined."
    pure (.noval, some e)

-- ---------------------------------------------------------------------------
-- transforms
-- ---------------------------------------------------------------------------

def transformRequest (ctx : Value) : SIO Value := do
  let specV ← gp ctx "spec"
  match specV with
  | .map _ => sp specV "step" (.str "reqform")
  | _ => pure ()
  let point ← gp ctx "point"
  let reqdata ← gp ctx "reqdata"
  match (← gp point "transform") with
  | .map i => do
    let reqform ← gp (.map i) "req"
    if isNov reqform then pure reqdata
    else do
      let input ← newMap #[("reqdata", reqdata)]
      transform input reqform
  | _ => pure reqdata

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
          transform input resform
      | _ => pure .noval
  | _ => pure .noval

/-- The request body: only data-input operations carry one. -/
def prepareBody (ctx : Value) : SIO Value := do
  if opInputOf (← opnameOf ctx) == "data" then transformRequest ctx
  else pure .noval

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
    else pure ()
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

def resultBody (ctx : Value) : SIO Unit := do
  let responseV ← gp ctx "response"
  let resultV ← gp ctx "result"
  match responseV, resultV with
  | .map _, .map _ => do
    let body ← gp responseV "body"
    if !(isNov body) then sp resultV "body" body
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
  sp spec "method" (.str (← prepareMethod ctx))
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
  pure (spec, none)

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
        let enc ← escurl (.str (vs v))
        sp resmatch k v
        url := url.replace ("{" ++ k ++ "}") (vs enc)
    let query ← gp specV "query"
    let mut qsep := "?"
    for k in (← keysof query) do
      let v ← gp query k
      if !(isNov v) then do
        let ek ← escurl (.str k)
        let ev ← escurl (.str (vs v))
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
    whose `select.exist` keys are all present and whose `$action` agrees. -/
def makePoint (ctx : Value) : SIO Value := do
  let op ← gp ctx "op"
  let matchV ← gp ctx "reqmatch"
  let dataV ← gp ctx "reqdata"
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
            if isNov (← gp matchV k) && isNov (← gp dataV k) then ok := false
        | _ => pure ()
        if ok && ((← gp sel "$action") == (← gp matchV "$action")) then
          chosen := pt
    -- select.exist can list more than the params needed to pick a point (for
    -- /boards/{id} it is Trello's 17 optional query-includes), so a plain
    -- {id} call matches NOTHING and this loop chose no point at all. Fall
    -- back to the entity's own route rather than sending nowhere.
    if isNov chosen then
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

/-- Remove configured sensitive keys (options.clean.keys) from a value. -/
def clean (ctx : Value) (v : Value) : SIO Value := do
  let options ← gp ctx "options"
  let keysStr ← gpS (← gp options "clean") "keys"
  let drop := if keysStr == "" then #[] else (keysStr.splitOn ",").toArray
  let out ← clone v
  match out with
  | .map _ =>
    for k in drop do
      if k != "" then dp out k
  | _ => pure ()
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
