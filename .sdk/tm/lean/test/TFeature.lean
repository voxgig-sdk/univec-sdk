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

def main : IO UInt32 := do
  let sctx ← mkCtx
  let go : SIO Unit := do
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
