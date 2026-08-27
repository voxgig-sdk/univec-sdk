/- ProjectName SDK feature catalog: the concrete features.

   Each constructor returns a `Feature` closing over its own state refs. A
   feature either wraps the transport (retry, timeout, ratelimit, cache, proxy,
   netsim, test) or handles pipeline hooks (idempotency, rbac, metrics,
   telemetry, debug, audit, clienttrack, paging, streaming) — or both.

   Observable state is recorded in the client's `track` buckets under the
   feature's own name, so behaviour is assertable from tests. -/

import VoxgigStruct
import SdkJson
import SdkUtility
import SdkFeature

open VoxgigStruct
open SdkFeature

namespace SdkFeatures

def gp := SdkUtility.gp
def sp := SdkUtility.sp
def gpS := SdkUtility.gpS
def vs := SdkUtility.vs
def isNov := SdkUtility.isNov
def truthy := SdkUtility.truthy

def statusOf (v : Value) : Float :=
  match v with
  | .map _ => 0.0
  | _ => 0.0

def numOf (v : Value) (d : Float) : Float :=
  match v with
  | .num n => n
  | _ => d

/-- Append a value to a struct list held at `key` on `parent`. -/
def appendTo (parent : Value) (key : String) (v : Value) : SIO Unit := do
  match (← gp parent key) with
  | .list i => do
    let items ← listItems i
    sp parent key (← newList (items.push v))
  | _ => sp parent key (← newList #[v])

-- ---------------------------------------------------------------------------
-- base / log
-- ---------------------------------------------------------------------------

def baseFeature : SIO Feature := do
  pure { name := "base" }

def logFeature : SIO Feature := do
  pure { name := "log"
       , hook := fun stage ctx => do
           if stage == "PreRequest" then do
             let b ← trackCtx ctx "log" (newMap #[("calls", .num 0.0)])
             bumpNum b "calls" 1.0 }

-- ---------------------------------------------------------------------------
-- retry
-- ---------------------------------------------------------------------------

def retryFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  let retryable (res : Value) (err : Option Value) (statuses : Array Float) : Bool :=
    match err with
    | some _ => true
    | none =>
      match res with
      | .noval => true
      | _ => false
  pure { name := "retry"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           if (← optActive opts) then do
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               let o ← optsR.get
               let retries := (← optInt o "retries" 2).toNat
               let minDelay ← optNum o "minDelay" 50.0
               let maxDelay ← optNum o "maxDelay" 2000.0
               let factor ← optNum o "factor" 2.0
               let mut attempt := 0
               let mut out ← inner c u f
               while attempt < retries do
                 let statusV ← gp out.1 "status"
                 let st := numOf statusV 0.0
                 let bad := (out.2.isSome) || st >= 500.0 || st == 429.0 || st == 408.0
                 if !bad then break
                 let mut delay := minDelay
                 for _ in [0:attempt] do delay := delay * factor
                 sleepMs (if delay > maxDelay then maxDelay else delay)
                 let b ← trackCtx c "retry" (newMap #[("attempts", .num 0.0)])
                 bumpNum b "attempts" 1.0
                 out ← inner c u f
                 attempt := attempt + 1
               pure out }

-- ---------------------------------------------------------------------------
-- timeout
-- ---------------------------------------------------------------------------

def timeoutFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  pure { name := "timeout"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           if (← optActive opts) then do
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               let o ← optsR.get
               let ms ← optNum o "ms" 30000.0
               if ms <= 0.0 then inner c u f
               else do
                 sp f "timeout" (.num (ms / 1000.0))
                 let start ← nowMs
                 let out ← inner c u f
                 let elapsed := (← nowMs) - start
                 if elapsed > ms then do
                   let b ← trackCtx c "timeout" (newMap #[("count", .num 0.0), ("ms", .num ms)])
                   bumpNum b "count" 1.0
                   let e ← SdkUtility.mkErr "timeout"
                     ("Request exceeded timeout of " ++ numToString ms ++ "ms")
                   pure (.noval, some e)
                 else pure out }

-- ---------------------------------------------------------------------------
-- ratelimit (token bucket)
-- ---------------------------------------------------------------------------

def ratelimitFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  let tokensR ← IO.mkRef (0.0 : Float)
  let lastR ← IO.mkRef (0.0 : Float)
  pure { name := "ratelimit"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           if (← optActive opts) then do
             let rate ← optNum om "rate" 5.0
             let burst ← optNum om "burst" rate
             tokensR.set burst
             lastR.set (← nowMs)
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               let o ← optsR.get
               let r ← optNum o "rate" 5.0
               let b ← optNum o "burst" r
               let now ← nowMs
               let elapsed := now - (← lastR.get)
               lastR.set now
               let tk0 := (← tokensR.get) + (elapsed / 1000.0) * r
               let tk := if tk0 > b then b else tk0
               if tk >= 1.0 then tokensR.set (tk - 1.0)
               else do
                 let waitMs := ((1.0 - tk) / r) * 1000.0
                 let bucket ← trackCtx c "ratelimit"
                   (newMap #[("throttled", .num 0.0), ("waitMs", .num 0.0)])
                 bumpNum bucket "throttled" 1.0
                 bumpNum bucket "waitMs" waitMs
                 sleepMs waitMs
                 lastR.set (← nowMs)
                 tokensR.set 0.0
               inner c u f }

-- ---------------------------------------------------------------------------
-- cache
-- ---------------------------------------------------------------------------

def cacheFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  let storeR ← IO.mkRef (← emptyMap)
  pure { name := "cache"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           if (← optActive opts) then do
             storeR.set (← emptyMap)
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               let o ← optsR.get
               let meth := upper (← gpS f "method")
               let methods ← optStrList o "methods" #["GET"]
               if !(methods.map upper).contains (if meth == "" then "GET" else meth) then
                 inner c u f
               else do
                 let key := meth ++ " " ++ u
                 let store ← storeR.get
                 let now ← nowMs
                 let hit ← gp store key
                 let fresh := match hit with
                   | .map _ => true
                   | _ => false
                 let expiry := numOf (← gp hit "expiry") 0.0
                 if fresh && expiry > now then do
                   let b ← trackCtx c "cache"
                     (newMap #[("hit", .num 0.0), ("miss", .num 0.0), ("bypass", .num 0.0)])
                   bumpNum b "hit" 1.0
                   pure ((← gp hit "snapshot"), none)
                 else do
                   let out ← inner c u f
                   let st := numOf (← gp out.1 "status") 0.0
                   let ok := out.2.isNone && st >= 200.0 && st < 300.0
                   let b ← trackCtx c "cache"
                     (newMap #[("hit", .num 0.0), ("miss", .num 0.0), ("bypass", .num 0.0)])
                   if ok then do
                     let ttl ← optNum o "ttl" 5000.0
                     let snap ← clone out.1
                     let entry ← newMap #[("expiry", .num (now + ttl)), ("snapshot", snap)]
                     sp store key entry
                     bumpNum b "miss" 1.0
                   else bumpNum b "bypass" 1.0
                   pure out }

-- ---------------------------------------------------------------------------
-- idempotency
-- ---------------------------------------------------------------------------

def idempotencyFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  pure { name := "idempotency"
       , init := fun _ opts => do optsR.set (← toOptsMap opts)
       , hook := fun stage ctx => do
           if stage == "PreRequest" then do
             let o ← optsR.get
             let specV ← gp ctx "spec"
             match specV with
             | .map _ => do
               let methods ← optStrList o "methods" #["POST", "PUT", "PATCH", "DELETE"]
               let meth := upper (← gpS specV "method")
               let ops ← optStrList o "ops" #["create", "update", "remove"]
               let opname ← SdkUtility.opnameOf ctx
               if (methods.map upper).contains meth || ops.contains opname then do
                 let header ← optStr o "header" "Idempotency-Key"
                 let hdrs ← SdkUtility.gpMap specV "headers"
                 if isNov (← headerCI hdrs header) then do
                   let key ← genId
                   sp hdrs header (.str key)
                   let b ← trackCtx ctx "idempotency"
                     (newMap #[("issued", .num 0.0), ("last", .noval)])
                   bumpNum b "issued" 1.0
                   sp b "last" (.str key)
             | _ => pure () }

-- ---------------------------------------------------------------------------
-- rbac (PrePoint short-circuit)
-- ---------------------------------------------------------------------------

def rbacFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  pure { name := "rbac"
       , init := fun _ opts => do optsR.set (← toOptsMap opts)
       , hook := fun stage ctx => do
           if stage == "PrePoint" then do
             let o ← optsR.get
             let opname ← SdkUtility.opnameOf ctx
             let perms ← optStrList o "perms" #[]
             let rules ← gp o "rules"
             let required ← gpS rules opname
             let deny := truthy (← gp o "deny")
             let needed := if required != "" then required else (if deny then "<default-deny>" else "")
             let allowed := needed == "" || perms.contains needed
             let b ← trackCtx ctx "rbac"
               (newMap #[("allowed", .num 0.0), ("denied", .num 0.0), ("last", .noval)])
             bumpNum b (if allowed then "allowed" else "denied") 1.0
             sp b "last" (.str needed)
             if !allowed then do
               let e ← SdkUtility.mkErr "rbac_denied"
                 ("Permission \"" ++ needed ++ "\" required for operation \"" ++ opname ++ "\"")
               let out ← SdkUtility.gpMap ctx "out"
               sp out "point" e }

-- ---------------------------------------------------------------------------
-- metrics
-- ---------------------------------------------------------------------------

def metricsFeature : SIO Feature := do
  let startR ← IO.mkRef (0.0 : Float)
  pure { name := "metrics"
       , hook := fun stage ctx => do
           let mk : SIO Value := do
             let tot ← newMap #[("count", .num 0.0), ("ok", .num 0.0), ("err", .num 0.0),
                                ("totalMs", .num 0.0), ("maxMs", .num 0.0)]
             let ops ← emptyMap
             newMap #[("total", tot), ("ops", ops)]
           if stage == "PreRequest" then startR.set (← nowMs)
           else if stage == "PreDone" then do
             let m ← trackCtx ctx "metrics" mk
             let dur := (← nowMs) - (← startR.get)
             let total ← gp m "total"
             let res ← gp ctx "result"
             let ok := truthy (← gp res "ok")
             bumpNum total "count" 1.0
             bumpNum total (if ok then "ok" else "err") 1.0
             bumpNum total "totalMs" dur
             if dur > numOf (← gp total "maxMs") 0.0 then sp total "maxMs" (.num dur)
             let opname ← SdkUtility.opnameOf ctx
             let ops ← gp m "ops"
             let key := (← gpS (← gp ctx "op") "entity") ++ "." ++ opname
             let opb ← (match (← gp ops key) with
               | .map i => pure (Value.map i)
               | _ => do
                 let b ← newMap #[("count", .num 0.0), ("ok", .num 0.0), ("err", .num 0.0),
                                  ("totalMs", .num 0.0), ("maxMs", .num 0.0)]
                 sp ops key b
                 pure b)
             bumpNum opb "count" 1.0
             bumpNum opb (if ok then "ok" else "err") 1.0
             bumpNum opb "totalMs" dur }

-- ---------------------------------------------------------------------------
-- telemetry (spans)
-- ---------------------------------------------------------------------------

def telemetryFeature : SIO Feature := do
  let spanR ← IO.mkRef (Value.noval)
  pure { name := "telemetry"
       , hook := fun stage ctx => do
           let mk : SIO Value := do
             let sp0 ← emptyList
             newMap #[("spans", sp0), ("active", .num 0.0)]
           if stage == "PrePoint" then do
             let t ← trackCtx ctx "telemetry" mk
             let opname ← SdkUtility.opnameOf ctx
             let sid ← genId
             let s ← newMap #[("id", .str ("s" ++ sid)), ("name", .str opname),
                              ("start", .num (← nowMs)), ("ok", .bool false)]
             spanR.set s
             appendTo t "spans" s
             bumpNum t "active" 1.0
           else if stage == "PreDone" then do
             let s ← spanR.get
             match s with
             | .map _ => do
               let t ← trackCtx ctx "telemetry" mk
               let endMs ← nowMs
               sp s "end" (.num endMs)
               sp s "durationMs" (.num (endMs - numOf (← gp s "start") 0.0))
               sp s "ok" (.bool (truthy (← gp (← gp ctx "result") "ok")))
               bumpNum t "active" (-1.0)
             | _ => pure () }

-- ---------------------------------------------------------------------------
-- debug (redacted request/response log)
-- ---------------------------------------------------------------------------

def debugFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  let entryR ← IO.mkRef (Value.noval)
  pure { name := "debug"
       , init := fun _ opts => do optsR.set (← toOptsMap opts)
       , hook := fun stage ctx => do
           let mk : SIO Value := do
             let es ← emptyList
             newMap #[("entries", es)]
           if stage == "PreRequest" then do
             let o ← optsR.get
             let d ← trackCtx ctx "debug" mk
             let patterns ← optStrList o "redact"
               #["authorization", "cookie", "set-cookie", "api-key", "apikey",
                 "x-api-key", "idempotency-key"]
             let specV ← gp ctx "spec"
             let hdrs ← gp specV "headers"
             let safe ← emptyMap
             match hdrs with
             | .map i =>
               for k in (← keysof (.map i)) do
                 if patterns.contains (lower k) then sp safe k (.str "<redacted>")
                 else sp safe k (← gp (.map i) k)
             | _ => pure ()
             let opname ← SdkUtility.opnameOf ctx
             let e ← newMap #[("op", .str opname), ("start", .num (← nowMs)),
                              ("headers", safe), ("ok", .bool false)]
             entryR.set e
             appendTo d "entries" e
           else if stage == "PreDone" then do
             let e ← entryR.get
             match e with
             | .map _ => do
               let endMs ← nowMs
               sp e "durationMs" (.num (endMs - numOf (← gp e "start") 0.0))
               let res ← gp ctx "result"
               sp e "ok" (.bool (truthy (← gp res "ok")))
               sp e "status" (← gp res "status")
             | _ => pure () }

-- ---------------------------------------------------------------------------
-- audit
-- ---------------------------------------------------------------------------

def auditFeature : SIO Feature := do
  pure { name := "audit"
       , hook := fun stage ctx => do
           if stage == "PreDone" then do
             let a ← trackCtx ctx "audit" (do let rs ← emptyList; newMap #[("records", rs)])
             let opname ← SdkUtility.opnameOf ctx
             let res ← gp ctx "result"
             let rec0 ← newMap #[("op", .str opname),
                                 ("entity", ← gp (← gp ctx "op") "entity"),
                                 ("ok", .bool (truthy (← gp res "ok"))),
                                 ("at", .num (← nowMs))]
             appendTo a "records" rec0 }

-- ---------------------------------------------------------------------------
-- clienttrack (request/session identity headers)
-- ---------------------------------------------------------------------------

def clienttrackFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  let sessionR ← IO.mkRef ""
  pure { name := "clienttrack"
       , init := fun _ opts => do
           optsR.set (← toOptsMap opts)
           if (← sessionR.get) == "" then sessionR.set ("s-" ++ (← genId))
       , hook := fun stage ctx => do
           if stage == "PreRequest" then do
             let o ← optsR.get
             let nm ← optStr o "clientName" "ProjectName-SDK"
             let ver ← optStr o "clientVersion" "0.0.1"
             let rid := "r-" ++ (← genId)
             let session ← sessionR.get
             let specV ← gp ctx "spec"
             let hdrs ← SdkUtility.gpMap specV "headers"
             let hopt ← gp o "headers"
             let reqH ← optStr hopt "request" "X-Request-Id"
             let sesH ← optStr hopt "session" "X-Session-Id"
             let cliH ← optStr hopt "client" "X-Client"
             if isNov (← headerCI hdrs reqH) then sp hdrs reqH (.str rid)
             if isNov (← headerCI hdrs sesH) then sp hdrs sesH (.str session)
             if isNov (← headerCI hdrs cliH) then sp hdrs cliH (.str (nm ++ "/" ++ ver))
             let b ← trackCtx ctx "clienttrack"
               (newMap #[("session", .str session), ("requests", .num 0.0),
                         ("clientName", .str nm)])
             bumpNum b "requests" 1.0
             sp b "lastRequestId" (.str rid) }

-- ---------------------------------------------------------------------------
-- paging / streaming
-- ---------------------------------------------------------------------------

def pagingFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  pure { name := "paging"
       , init := fun _ opts => do optsR.set (← toOptsMap opts)
       , hook := fun stage ctx => do
           if stage == "PreSpec" then do
             let o ← optsR.get
             let opname ← SdkUtility.opnameOf ctx
             if opname == "list" then do
               let sizeKey ← optStr o "sizeParam" "limit"
               let pageKey ← optStr o "pageParam" "page"
               let sizeV ← gp o "size"
               let specV ← gp ctx "spec"
               match specV with
               | .map _ => do
                 let q ← SdkUtility.gpMap specV "query"
                 if !(isNov sizeV) then sp q sizeKey sizeV
                 let pageV ← gp o "page"
                 if !(isNov pageV) then sp q pageKey pageV
                 let b ← trackCtx ctx "paging"
                   (newMap #[("pages", .num 0.0), ("items", .num 0.0)])
                 bumpNum b "pages" 1.0
               | _ => pure ()
           else if stage == "PreDone" then do
             let opname ← SdkUtility.opnameOf ctx
             if opname == "list" then do
               let res ← gp ctx "result"
               let n ← (match (← gp res "resdata") with
                 | .list i => do pure (← listItems i).size
                 | _ => pure 0)
               let b ← trackCtx ctx "paging"
                 (newMap #[("pages", .num 0.0), ("items", .num 0.0)])
               bumpNum b "items" n.toFloat }

-- ---------------------------------------------------------------------------
-- cost
-- ---------------------------------------------------------------------------
-- Prices every transport ATTEMPT and commits the spend once per OPERATION.
-- Mirrors tm/ts/src/feature/cost/CostFeature.ts.
--
-- ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
-- cache is charged for money that was never spent.

def costFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  -- Accumulated per call and committed once: adding each attempt to the
  -- running total and subtracting it again loses precision.
  let pendR ← IO.mkRef (← newMap #[("attempts", Value.num 0.0), ("amount", Value.num 0.0),
                                   ("reported", Value.num 0.0), ("estimated", Value.num 0.0),
                                   ("source", Value.str "none")])
  let seqR ← IO.mkRef 0

  let record : Value → SIO Value := fun ctx => do
    let o ← optsR.get
    let cur ← optStr o "currency" "USD"
    let lim ← optNum o "budget" 0.0
    let total ← newMap #[("calls", Value.num 0.0), ("attempts", Value.num 0.0),
                         ("amount", Value.num 0.0), ("reported", Value.num 0.0),
                         ("estimated", Value.num 0.0)]
    let ops ← emptyMap
    let actors ← emptyMap
    let budget ← newMap #[("limit", Value.num lim), ("spent", Value.num 0.0),
                          ("remaining", Value.num lim), ("exceeded", Value.bool false)]
    trackCtx ctx "cost" (newMap #[("currency", Value.str cur), ("total", total),
                                  ("ops", ops), ("actors", actors), ("budget", budget),
                                  ("last", Value.noval)])

  let resetPending : SIO Unit := do
    let p ← newMap #[("attempts", Value.num 0.0), ("amount", Value.num 0.0),
                     ("reported", Value.num 0.0), ("estimated", Value.num 0.0),
                     ("source", Value.str "none")]
    pendR.set p

  -- Pricing precedence: a server-stated header beats the rate table, which
  -- beats the flat unit.
  let priceOf : Value → Value → SIO (Float × String) := fun ctx res => do
    let o ← optsR.get
    let perUnit ← optNum o "perUnit" 0.0
    let hname ← optStr o "header" ""
    let hv ← if hname == "" then pure Value.noval else headerCI (← gp res "headers") hname
    let hn := numOf hv (-1.0)
    if hname != "" && hn >= 0.0 then
      pure (hn * perUnit, "header")
    else do
      let rates ← gp o "rates"
      let opname ← SdkUtility.opnameOf ctx
      let byOp := numOf (← gp rates opname) (-1.0)
      let byAny := numOf (← gp rates "*") (-1.0)
      if byOp >= 0.0 then pure (byOp, "table")
      else if byAny >= 0.0 then pure (byAny, "table")
      else do
        let unit ← optNum o "unit" 0.0
        if unit != 0.0 then pure (unit, "unit") else pure (0.0, "none")

  let bucketOf : Value → String → SIO Value := fun bucket key => do
    let b ← gp bucket key
    match b with
    | Value.map _ => pure b
    | _ => do
        let m ← newMap #[("calls", Value.num 0.0), ("amount", Value.num 0.0)]
        sp bucket key m
        pure m

  let commit : Value → SIO Unit := fun ctx => do
    let o ← optsR.get
    let p ← pendR.get
    let rec_ ← record ctx
    let amount := numOf (← gp p "amount") 0.0
    let total ← gp rec_ "total"
    bumpNum total "amount" amount
    bumpNum total "reported" (numOf (← gp p "reported") 0.0)
    bumpNum total "estimated" (numOf (← gp p "estimated") 0.0)
    bumpNum total "calls" 1.0

    let budget ← gp rec_ "budget"
    let lim := numOf (← gp budget "limit") 0.0
    let spent := numOf (← gp total "amount") 0.0
    sp budget "spent" (Value.num spent)
    sp budget "remaining"
      (Value.num (if lim > 0.0 then (if lim - spent > 0.0 then lim - spent else 0.0) else 0.0))
    if lim > 0.0 && spent >= lim then sp budget "exceeded" (Value.bool true)

    let opname ← SdkUtility.opnameOf ctx
    let actorV ← gp (← gp ctx "ctrl") "actor"
    let actorS := match actorV with | Value.str a => a | _ => ""
    let actor ← if actorS != "" then pure actorS else optStr o "actor" "anonymous"

    let opB ← bucketOf (← gp rec_ "ops") ("_." ++ opname)
    bumpNum opB "calls" 1.0
    bumpNum opB "amount" amount
    let acB ← bucketOf (← gp rec_ "actors") actor
    bumpNum acB "calls" 1.0
    bumpNum acB "amount" amount

    let n ← seqR.modifyGet fun n => (n + 1, n + 1)
    let last ← newMap #[("seq", Value.num n.toFloat), ("op", Value.str opname),
                        ("actor", Value.str actor), ("amount", Value.num amount),
                        ("currency", ← gp rec_ "currency"), ("source", ← gp p "source"),
                        ("attempts", ← gp p "attempts")]
    sp rec_ "last" last
    resetPending

  pure { name := "cost"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           resetPending
           if (← optActive opts) then do
             let _ ← record ctx
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               -- The transport answers (response, error): a rejecting attempt
               -- still costs, or a run of failures under retry would be free.
               let (res, rerr) ← inner c u f
               let (amount, source) ← priceOf c res
               let p ← pendR.get
               bumpNum p "attempts" 1.0
               bumpNum p "amount" amount
               bumpNum p (if source == "header" then "reported" else "estimated") amount
               sp p "source" (Value.str source)
               let rec_ ← record c
               bumpNum (← gp rec_ "total") "attempts" 1.0
               pure (res, rerr)
       , hook := fun stage ctx => do
           let o ← optsR.get
           if stage == "PrePoint" then do
             let lim ← optNum o "budget" 0.0
             if lim > 0.0 then do
               let rec_ ← record ctx
               let spent := numOf (← gp (← gp rec_ "total") "amount") 0.0
               if spent >= lim then do
                 sp (← gp rec_ "budget") "exceeded" (Value.bool true)
                 if (← optStr o "onBudget" "warn") == "deny" then do
                   let e ← SdkUtility.mkErr "cost_budget"
                     ("Cost budget of " ++ toString lim ++ " is spent")
                   let out ← SdkUtility.gpMap ctx "out"
                   sp out "point" e
           else if stage == "PreDone" then do
             -- A cache hit is a real call that cost nothing, so it commits
             -- too: that is the point of ordering cost inside the cache.
             commit ctx }

def streamingFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  pure { name := "streaming"
       , init := fun _ opts => do optsR.set (← toOptsMap opts)
       , hook := fun stage ctx => do
           if stage == "PreDone" then do
             let res ← gp ctx "result"
             let items ← gp res "resdata"
             match items with
             | .list i => do
               let its ← listItems i
               let b ← trackCtx ctx "streaming"
                 (newMap #[("emitted", .num 0.0), ("chunks", .num 0.0)])
               bumpNum b "emitted" its.size.toFloat
               bumpNum b "chunks" 1.0
             | _ => pure () }

-- ---------------------------------------------------------------------------
-- proxy
-- ---------------------------------------------------------------------------

def proxyFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  pure { name := "proxy"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           if (← optActive opts) then do
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               let o ← optsR.get
               let purl ← gpS o "url"
               if purl == "" then inner c u f
               else do
                 sp f "proxy" (.str purl)
                 let proxies ← newMap #[("http", .str purl), ("https", .str purl)]
                 sp f "proxies" proxies
                 let b ← trackCtx c "proxy"
                   (newMap #[("routed", .num 0.0), ("url", .str purl)])
                 bumpNum b "routed" 1.0
                 inner c u f }

-- ---------------------------------------------------------------------------
-- netsim (offline / latency / failStatus simulation)
-- ---------------------------------------------------------------------------

def netsimFeature : SIO Feature := do
  let optsR ← IO.mkRef (← emptyMap)
  let seedR ← IO.mkRef (12345 : Nat)
  let callR ← IO.mkRef (0 : Nat)
  pure { name := "netsim"
       , init := fun ctx opts => do
           let om ← toOptsMap opts
           optsR.set om
           if (← optActive opts) then do
             let client ← clientOf ctx
             let inner ← getFetcher client
             setFetcher client fun c u f => do
               let o ← optsR.get
               let call := (← callR.get) + 1
               callR.set call
               let applied ← emptyMap
               let b ← trackCtx c "netsim"
                 (do let ap ← emptyList; newMap #[("calls", .num 0.0), ("applied", ap)])
               bumpNum b "calls" 1.0
               -- deterministic LCG for latency jitter
               let s := ((← seedR.get) * 1103515245 + 12345) % 2147483648
               seedR.set s
               let lat ← optNum o "latency" 0.0
               if lat > 0.0 then sleepMs lat
               if truthy (← gp o "offline") then do
                 sp applied "offline" (.bool true)
                 appendTo b "applied" applied
                 let e ← SdkUtility.mkErr "netsim_offline"
                   ("Simulated network offline (URL was: \"" ++ u ++ "\")")
                 pure (.noval, some e)
               else do
                 let fs ← optNum o "failStatus" 0.0
                 if fs > 0.0 then do
                   sp applied "failStatus" (.num fs)
                   appendTo b "applied" applied
                   let resp ← newMap #[("status", .num fs), ("statusText", .str "Simulated"),
                                       ("body", ← emptyMap)]
                   pure (resp, none)
                 else do
                   appendTo b "applied" applied
                   inner c u f }

-- ---------------------------------------------------------------------------
-- the catalog
-- ---------------------------------------------------------------------------

/-- Every feature by name (the factory the client uses). -/
def makeFeature (name : String) : SIO Feature :=
  match name with
  | "log" => logFeature
  | "retry" => retryFeature
  | "timeout" => timeoutFeature
  | "ratelimit" => ratelimitFeature
  | "cache" => cacheFeature
  | "idempotency" => idempotencyFeature
  | "rbac" => rbacFeature
  | "metrics" => metricsFeature
  | "telemetry" => telemetryFeature
  | "debug" => debugFeature
  | "audit" => auditFeature
  | "clienttrack" => clienttrackFeature
  | "paging" => pagingFeature
  | "streaming" => streamingFeature
  | "proxy" => proxyFeature
  | "netsim" => netsimFeature
  | "cost" => costFeature
  | _ => baseFeature

/-- The catalog order: transport wrappers compose in this order. -/
def featureNames : Array String :=
  #["log", "rbac", "idempotency", "clienttrack", "paging", "streaming",
    "metrics", "telemetry", "debug", "audit",
    "cost", "cache", "ratelimit", "timeout", "retry", "proxy", "netsim"]

end SdkFeatures
