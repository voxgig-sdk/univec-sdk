/- Univec SDK pipeline test: the request-shaping utilities driven
   directly. A header, cookie or query argument travels where the definition
   declares it (the ts pathquery.test.ts cases), the media headers follow the
   point, and a routed argument stays out of the body. -/

import VoxgigStruct
import SdkJson
import SdkUtility
import SdkRuntime

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
def isNov := SdkUtility.isNov

def has (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- The error a response the transport marked as not JSON leaves on the result,
    as its code and message. -/
def unreadableErr (status : Float) (ctype : Option String) (body : String) :
    SIO (String × String) := do
  let hs ← newMap (match ctype with | some t => #[("content-type", Value.str t)] | none => #[])
  let response ← newMap #[("status", .num status),
    ("statusText", .str (if status < 400.0 then "OK" else "ERR")), ("headers", hs),
    ("body", .str body), ("unreadable", .bool true)]
  let spec ← newMap #[("headers", ← newMap #[("user-agent", .str "Probe/1.0")])]
  let ctx ← newMap #[("response", response), ("result", ← newMap #[("ok", .bool false)]),
                     ("spec", spec)]
  SdkUtility.resultBasic ctx
  SdkUtility.resultHeaders ctx
  SdkUtility.resultBody ctx
  let e ← gp (← gp ctx "result") "err"
  pure (← gpS e "code", ← gpS e "message")

/-- A ctx whose options send the given default headers, with the given point,
    match and data. -/
def argCtx (headers point reqmatch reqdata : Array (String × Value)) : SIO Value := do
  let opts ← newMap #[("headers", ← newMap headers)]
  newMap #[("options", opts), ("point", ← newMap point),
           ("reqmatch", ← newMap reqmatch), ("reqdata", ← newMap reqdata)]

def argDef (p : String × String) : SIO Value :=
  newMap #[("name", .str p.1), ("orig", .str p.2)]

def defs (pairs : Array (String × String)) : SIO Value := do
  newList (← pairs.mapM argDef)

def cookieArgs : SIO Value := do
  newMap #[("header", ← defs #[("x_trace", "X-Trace")]),
           ("cookie", ← defs #[("session_id", "SESSIONID"), ("theme", "theme"), ("prefs", "prefs")])]

def queryArgs : SIO Value := do
  newMap #[("params", ← newList #[← newMap #[("name", .str "id")]]),
           ("query", ← defs #[("page_size", "pageSize"), ("lang", "lang"), ("trace", "trace")]),
           ("header", ← defs #[("x_trace", "X-Trace"), ("trace", "trace")]),
           ("cookie", ← defs #[("session_id", "SESSIONID"), ("lang", "lang")])]

/-- The allow gates on an empty, null or non-map option, and on none at all.
    A definition of its own, as the compiler limits `main`. -/
def allowEdgeCases : SIO Unit := do
  let point ← newMap #[("method", .str "GET"), ("parts", ← newList #[.str "a"])]
  let opCode (options : Value) : SIO String := do
    let op ← newMap #[("name", .str "load"), ("points", ← newList #[point])]
    gpS (← SdkUtility.makePoint (← newMap #[("op", op), ("options", options)])) "code"
  let specCode (options : Value) : SIO String := do
    let ctx ← newMap #[("options", options), ("point", point), ("opname", .str "load")]
    match (← SdkUtility.makeSpec ctx) with
    | (_, some e) => gpS e "code"
    | (_, none) => pure ""
  let allowing (key : String) (v : Value) : SIO Value := do
    newMap #[("allow", ← newMap #[(key, v)])]
  let scalar ← newMap #[("allow", .str "load,GET")]
  let bare ← emptyMap
  let other ← allowing "other" (.str "x")
  check ((← opCode (← allowing "op" (.str ""))) == "point_op_allow"
      && (← opCode (← allowing "op" .null)) == "point_op_allow"
      && (← opCode scalar) == "point_op_allow")
    "makePoint: an empty, null or non-map allow.op refuses every operation"
  check ((← specCode (← allowing "method" (.str ""))) == "spec_method_allow"
      && (← specCode (← allowing "method" .null)) == "spec_method_allow"
      && (← specCode scalar) == "spec_method_allow")
    "makeSpec: an empty, null or non-map allow.method refuses every method"
  check ((← opCode bare) == "" && (← opCode other) == ""
      && (← specCode bare) == "" && (← specCode other) == "")
    "makePoint, makeSpec: a hand-built context with no allow option allows"

/-- A header, cookie or query argument the point marks as a field the body
    keeps stays in the body, beside an unmarked one that leaves it. -/
def fieldArgCase : SIO Unit := do
  let tr ← newMap #[("req", .str "`reqdata`")]
  let mut kept := true
  for kind in #["header", "cookie", "query"] do
    let locale ← newMap #[("name", .str "locale"), ("orig", .str "Locale"), ("field", .bool true)]
    let args ← newMap #[(kind, ← newList #[locale, ← argDef ("session_id", "SESSIONID")])]
    let ctx ← argCtx #[] #[("args", args), ("transform", tr)] #[]
      #[("name", .str "n"), ("locale", .str "en"), ("session_id", .str "s1")]
    let b ← SdkUtility.transformRequest ctx
    kept := kept && (← keysof b) == #["locale", "name"] && (← gpS b "locale") == "en"
  check kept "transformRequest: an argument the point marks as a field the body keeps stays in the body"

def patchInputCase : SIO Unit := do
  check (SdkUtility.opInputOf "patch" == "data" && SdkUtility.opInputOf "update" == "data"
      && SdkUtility.opInputOf "load" == "match")
    "opInputOf: a patch, like an update, takes the request data as its input"

def main : IO UInt32 := do
  let sctx ← mkCtx
  let go : SIO Unit := do
    (do
      let point ← newMap #[("method", .str "GET"), ("parts", ← newList #[.str "a"])]
      let attempt (allowop : Value) : SIO Value := do
        let op ← newMap #[("name", .str "load"), ("points", ← newList #[point])]
        let options ← newMap #[("allow", ← newMap #[("op", allowop)])]
        SdkUtility.makePoint (← newMap #[("op", op), ("options", options)])
      let refused ← attempt (.str "reload,unload")
      let named ← attempt (.str "list,\n LOAD")
      check ((← gpS refused "code") == "point_op_allow" && (← gpS named "method") == "GET")
        "makePoint: an allow list names whole operations, in any case"
      let numbered ← attempt (.num 5.0)
      let listed ← attempt (← newList #[.str "load"])
      check ((← gpS numbered "code") == "point_op_allow" && (← gpS listed "code") == "point_op_allow")
        "makePoint: an allow.op that is not a string allows nothing")

    allowEdgeCases

    (do
      let hdefs ← defs #[("idempotency_key", "Idempotency-Key"), ("page_size", "Page-Size")]
      let args ← newMap #[("header", hdefs)]
      let ctx ← argCtx #[("Idempotency-Key", .str "default"), ("user-agent", .str "sdk")]
        #[("args", args)] #[("idempotency_key", .str "k1")] #[("page_size", .str "3")]
      let h ← SdkUtility.prepareHeaders ctx
      check ((← gpS h "idempotency-key") == "k1" && isNov (← gp h "Idempotency-Key")
          && (← gpS h "page-size") == "3" && (← gpS h "user-agent") == "sdk")
        "prepareHeaders: a header argument replaces a default of the same name, in any case")

    (do
      let theme ← newList #[.str "dark", .str "x y"]
      let prefs ← newMap #[("lang", .str "en gb"), ("size", .str "2")]
      let ctx ← argCtx #[] #[("args", ← cookieArgs)] #[("session_id", .str "a b;c,d")]
        #[("theme", theme), ("prefs", prefs)]
      let h ← SdkUtility.prepareHeaders ctx
      check ((← gpS h "cookie") == "SESSIONID=a%20b%3Bc%2Cd; theme=dark; theme=x%20y; lang=en%20gb; size=2")
        "prepareHeaders: a cookie argument is form serialized and percent-encoded, one cookie per pair")

    (do
      let ctx ← argCtx #[("Cookie", .str "SESSIONID=old; session=a=b&theme=old ;lang=en"), ("user-agent", .str "sdk")]
        #[("args", ← cookieArgs)] #[("session_id", .str "s1")] #[("theme", .str "dark")]
      let h ← SdkUtility.prepareHeaders ctx
      check ((← gpS h "cookie") == "session=a=b&theme=old; lang=en; SESSIONID=s1; theme=dark"
          && isNov (← gp h "Cookie") && (← gpS h "user-agent") == "sdk")
        "prepareHeaders: a same-named cookie is replaced, every other kept whole")

    (do
      let prefs ← newMap #[("x y", .str "new")]
      let ctx ← argCtx #[("Cookie", .str "x%20y=old; theme=dark")] #[("args", ← cookieArgs)]
        #[("session_id", .str "s1")] #[("prefs", prefs)]
      let h ← SdkUtility.prepareHeaders ctx
      check ((← gpS h "cookie") == "theme=dark; SESSIONID=s1; x%20y=new")
        "prepareHeaders: a map cookie argument replaces a default under its encoded key")

    (do
      let ctx ← argCtx #[("Cookie", .str "lang=en")] #[("args", ← cookieArgs)]
        #[("session_id", .null)] #[]
      let h ← SdkUtility.prepareHeaders ctx
      check ((← gpS h "Cookie") == "lang=en" && isNov (← gp h "cookie"))
        "prepareHeaders: an absent or null cookie argument leaves the headers alone")

    (do
      let media ← newMap #[("kind", .str "json"), ("media", .str "application/vnd.api+json")]
      let ctx ← argCtx #[("content-type", .str "application/json")]
        #[("response", media), ("body", media)] #[] #[]
      let h ← SdkUtility.prepareHeaders ctx
      check ((← gpS h "accept") == "application/vnd.api+json"
          && (← gpS h "content-type") == "application/vnd.api+json")
        "prepareHeaders: the declared media is asked for and replaces the JSON default"
      let ctx2 ← argCtx #[("Accept", .str "text/plain"), ("content-type", .str "text/plain")]
        #[("response", media), ("body", media)] #[] #[]
      let h2 ← SdkUtility.prepareHeaders ctx2
      check ((← gpS h2 "Accept") == "text/plain" && isNov (← gp h2 "accept")
          && (← gpS h2 "content-type") == "text/plain")
        "prepareHeaders: a caller's accept and content-type win")

    (do
      let ctx ← argCtx #[] #[("params", ← newList #[.str "id"]), ("args", ← queryArgs)]
        #[("id", .str "i1"), ("x_trace", .str "t1"), ("session_id", .str "s1"), ("q", .str "x"),
          ("$action", .str "a"), ("page_size", .str "3"), ("lang", .str "en"), ("trace", .str "t1")] #[]
      let q ← SdkUtility.prepareQuery ctx
      check ((← keysof q) == #["lang", "pageSize", "q", "trace"] && (← gpS q "pageSize") == "3"
          && (← gpS q "lang") == "en" && (← gpS q "trace") == "t1" && (← gpS q "q") == "x")
        "prepareQuery: path, header and cookie arguments stay out, a query argument goes under its orig")

    (do
      let ctx ← argCtx #[] #[("args", ← queryArgs)] #[] #[("page_size", .str "3"), ("lang", .str "en")]
      let q ← SdkUtility.prepareQuery ctx
      check ((← keysof q) == #["lang", "pageSize"] && (← gpS q "pageSize") == "3")
        "prepareQuery: a query argument is taken from the data")

    (do
      let tr ← newMap #[("req", .str "`reqdata`")]
      let ctx ← argCtx #[] #[("args", ← queryArgs), ("transform", tr)] #[]
        #[("x_trace", .str "t1"), ("session_id", .str "s1"), ("page_size", .str "2"),
          ("title", .str "T"), ("$action", .str "a")]
      let b ← SdkUtility.transformRequest ctx
      check ((← keysof b) == #["title"] && (← gpS b "title") == "T")
        "transformRequest: a routed argument is left out of the body")

    fieldArgCase

    (do
      let body ← newMap #[("kind", .str "raw"), ("media", .str "text/plain")]
      let ctx ← argCtx #[] #[("body", body)] #[] #[("$body", .str "hello")]
      SdkUtility.sp ctx "opname" (.str "create")
      let b ← SdkUtility.prepareBody ctx
      check (b == .str "hello") "prepareBody: a raw request body is sent as given")

    (do
      let raw ← newMap #[("body", ← newMap #[("kind", .str "raw"), ("media", .str "text/plain")])]
      let json ← newMap #[("body", ← newMap #[("kind", .str "json"), ("media", .str "application/json")])]
      check ((← SdkUtility.bodyText raw (.str "hello")) == some "hello")
        "bodyText: a raw point's string body is sent as given"
      check ((← SdkUtility.bodyText json (.str "hello")) == some "\"hello\"")
        "bodyText: a JSON point's string body is sent as JSON"
      let node ← newMap #[("a", .str "b")]
      check ((← SdkUtility.bodyText json node) == some (← jsonify node)
          && (← SdkUtility.bodyText json .noval) == none)
        "bodyText: a node is JSON and no body is none")

    (do
      check (SdkJson.jsonValid "[{\"id\":\"x01\",\"n\":-1.5e3,\"ok\":true,\"no\":null}]"
          && SdkJson.jsonValid " {} " && !(SdkJson.jsonValid "{\"id\": \"x01\", \"title\": ")
          && !(SdkJson.jsonValid "not json at all") && !(SdkJson.jsonValid "[1, 2] x")
          && !(SdkJson.jsonValid "{\"a\" 1}") && !(SdkJson.jsonValid "nul"))
        "jsonValid: one whole JSON value, nothing truncated, misspelt or trailing")

    (do
      let bare ← newMap #[("method", .str "GET")]
      let sent ← SdkRuntime.sentHeaders bare
      let own ← newMap #[("headers", ← newMap #[("User-Agent", .str "Probe/1.0")])]
      let mine ← SdkRuntime.sentHeaders own
      check (SdkRuntime.defaultUserAgent == "Mozilla/5.0 (compatible; UnivecSDK/1.0)"
          && sent == #[("user-agent", SdkRuntime.defaultUserAgent)]
          && (← gpS (← gp bare "headers") "user-agent") == SdkRuntime.defaultUserAgent
          && mine == #[("User-Agent", "Probe/1.0")]
          && isNov (← gp (← gp own "headers") "user-agent"))
        "sentHeaders: the default agent, recorded, unless the request names one")

    (do
      check (SdkRuntime.bodyUnreadable "<p>challenge</p>" && SdkRuntime.bodyUnreadable "{\"a\": "
          && !(SdkRuntime.bodyUnreadable " \n ") && !(SdkRuntime.bodyUnreadable "")
          && !(SdkRuntime.bodyUnreadable "[{\"id\": 1}]"))
        "bodyUnreadable: a body that is neither blank nor one JSON value")

    (do
      let (c1, m1) ← unreadableErr 200.0 (some "application/json") "{\"a\": "
      check (c1 == "response_json_invalid" && has m1 ("body is not valid JSON (HTTP 200, " ++
          "content-type application/json, user-agent Probe/1.0, body: {\"a\":)"))
        "resultBody: a body labelled as JSON that does not parse"
      let (c2, m2) ← unreadableErr 200.0 none "not json"
      check (c2 == "response_json_invalid" && has m2 "content-type none")
        "resultBody: an unlabelled body that is not JSON"
      let (c3, m3) ← unreadableErr 200.0 (some "text/html") ("<p>\n  challenge </p>" ++ "".pushn 'x' 300)
      check (c3 == "response_content_type" && has m3 "expected JSON, got text/html"
          && has m3 "body: <p> challenge </p>xxx" && m3.endsWith "...)")
        "resultBody: a body labelled as something else, its preview bounded"
      let (c4, m4) ← unreadableErr 503.0 (some "text/html") "<p>down</p>"
      check (c4 == "request_status" && has m4 ("request: 503: ERR (HTTP 503, content-type " ++
          "text/html, user-agent Probe/1.0, body: <p>down</p>)"))
        "resultBody: an HTTP failure keeps its error, the body described")

    (do
      let urlFor (base path : String) : SIO (Value × Option Value) := do
        let spec ← newMap #[("base", .str base), ("path", .str path), ("params", ← emptyMap)]
        SdkUtility.makeUrl (← newMap #[("spec", spec)])
      let (_, e1) ← urlFor "http://h" "planet/{planet_id}/moon/{id}"
      let (code, msg) ← match e1 with
        | some e => pure (← gpS e "code", ← gpS e "message")
        | none => pure ("", "")
      check (code == "url_param_missing" && msg == "URL path has no value for {planet_id}, {id}.")
        "makeUrl: an unfilled route is refused"
      let mut kept := true
      for base in ["https://api.example.test/bot{token}", "http://{{base_url}}", "http://{test-base_url}/"] do
        if (← urlFor base "planet").2.isSome then kept := false
      let (_, e2) ← urlFor "http://{{base_url}}" "planet/{id}"
      let m2 ← match e2 with | some e => gpS e "message" | none => pure ""
      check (kept && m2 == "URL path has no value for {id}.")
        "makeUrl: a placeholder in the base is a server variable")

    patchInputCase

  go.run sctx
  let p ← npass.get
  let f ← nfail.get
  IO.println ""
  IO.println s!"pipeline: PASS {p}  FAIL {f}"
  if f > 0 then return 1 else return 0
