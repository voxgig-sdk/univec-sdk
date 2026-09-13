-- Feature behaviour tests. Each feature is driven through the mini operation
-- pipeline (Harness) against a mock transport, with injected clocks / idgen /
-- keygen so timing and id features are deterministic. Feature tracking is
-- inspected on client._<name> (trackGet); where a feature exposes no track
-- field the sent request (recordingServer) or the op result is asserted.
-- Mirrors the rust donor tests/feature_test.rs at the same depth.

{-# LANGUAGE ScopedTypeVariables #-}

module TFeature (tests) where

import Control.Monad (forM_)
import Data.IORef
import System.Environment (lookupEnv, setEnv, unsetEnv)

import VoxgigStruct (Value (..), emptyMap, emptyList, isNoval)
import SdkTypes
import SdkHelpers
import Harness
import Testutil

-- number field of a tracking bucket (absent -> -999)
bnum :: Value -> String -> IO Double
bnum m k = do v <- getp m k; pure (case v of VNum n -> n; _ -> -999)

-- length of a list-valued bucket field (absent -> 0)
blen :: Value -> String -> IO Int
blen m k = do v <- getp m k; case v of VList r -> length <$> readIORef r; _ -> pure 0

-- header on the op's final spec (features stamp spec.headers during PreRequest)
specHeader :: OpResult -> String -> IO Value
specHeader r name = do
  sp <- readIORef (cSpec (orCtx r))
  case sp of { VMap _ -> do { h <- getp sp "headers"; headerCI h name }; _ -> pure VNoval }

-- recorded (call n) fetchdef / header / url off a recordingServer
recAt :: IORef [Value] -> Int -> IO Value
recAt calls i = do cs <- readIORef calls; pure (if i >= 0 && i < length cs then cs !! i else VNoval)

recFetchdef :: IORef [Value] -> Int -> IO Value
recFetchdef calls i = do r <- recAt calls i; getp r "fetchdef"

recHeader :: IORef [Value] -> Int -> String -> IO Value
recHeader calls i name = do fd <- recFetchdef calls i; h <- getp fd "headers"; headerCI h name

recUrl :: IORef [Value] -> Int -> IO String
recUrl calls i = do r <- recAt calls i; getStrD r "url" ""

-- resmap status (feature failure surfaces status onto the result map)
resStatus :: OpResult -> IO Int
resStatus r = do st <- getp (orResult r) "status"; pure (toInt st)

resHeader :: OpResult -> String -> IO Value
resHeader r name = do h <- getp (orResult r) "headers"; case h of { VMap _ -> headerCI h name; _ -> pure VNoval }

startsWith :: String -> String -> Bool
startsWith pfx s = take (length pfx) s == pfx

endsW :: String -> String -> Bool
endsW suf s = length s >= length suf && drop (length s - length suf) s == suf

vfnStr :: (String -> String) -> Value
vfnStr f = VFunc (\_ v _ _ -> pure (VStr (f (vstring v))))

listVals :: Value -> IO [Value]
listVals v = case v of VList r -> readIORef r; _ -> pure []

tests :: Counters -> IO ()
tests c = do

  ---------------------------------------------------------------- netsim
  runTest c "feature.netsim_fixed_latency_then_delegate" $ do
    clk <- makeClock
    ex <- emptyMap; ctrl <- jo [("explain", ex)]
    nopts <- jo [("latency", VNum 250), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    res <- runOpH h (defaultOpArgs { oaCtrl = ctrl })
    t <- clockNow clk
    bucket <- trackGet (hClient h) "netsim"
    calls <- bnum bucket "calls"
    pure (orOk res && t == 250 && calls == 1)

  runTest c "feature.netsim_ranged_latency_in_min_max" $ do
    clk <- makeClock
    latm <- jo [("min", VNum 100), ("max", VNum 300)]
    nopts <- jo [("latency", latm), ("seed", VNum 7), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    t <- clockNow clk
    pure (t >= 100 && t < 300)

  runTest c "feature.netsim_equal_min_max_latency_exact" $ do
    clk <- makeClock
    latm <- jo [("min", VNum 50), ("max", VNum 50)]
    nopts <- jo [("latency", latm), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    t <- clockNow clk
    pure (t == 50)

  runTest c "feature.netsim_fail_times_returns_retryable_status" $ do
    nopts <- jo [("failTimes", VNum 2), ("failStatus", VNum 503)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    r1 <- runOpH h defaultOpArgs; s1 <- resStatus r1
    r2 <- runOpH h defaultOpArgs; s2 <- resStatus r2
    r3 <- runOpH h defaultOpArgs
    pure (s1 == 503 && s2 == 503 && orOk r3)

  runTest c "feature.netsim_fail_every_fails_every_nth" $ do
    nopts <- jo [("failEvery", VNum 2)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    r1 <- runOpH h defaultOpArgs
    r2 <- runOpH h defaultOpArgs
    r3 <- runOpH h defaultOpArgs
    pure (orOk r1 && not (orOk r2) && orOk r3)

  runTest c "feature.netsim_fail_rate_with_seed_deterministic" $ do
    nopts <- jo [("failRate", VNum 1), ("seed", VNum 5)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    res <- runOpH h defaultOpArgs
    pure (not (orOk res))

  runTest c "feature.netsim_error_times_connection_error" $ do
    nopts <- jo [("errorTimes", VNum 1)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    res <- runOpH h defaultOpArgs
    ecode <- case orErr res of Just e -> errCode e; Nothing -> pure ""
    pure (not (orOk res) && ecode == "netsim_conn")

  runTest c "feature.netsim_offline_fails_every_call" $ do
    nopts <- jo [("offline", VBool True)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    res <- runOpH h defaultOpArgs
    ecode <- case orErr res of Just e -> errCode e; Nothing -> pure ""
    pure (not (orOk res) && ecode == "netsim_offline")

  runTest c "feature.netsim_rate_limit_times_429_retry_after" $ do
    nopts <- jo [("rateLimitTimes", VNum 1), ("retryAfter", VNum 3)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    res <- runOpH h defaultOpArgs
    st <- resStatus res
    ra <- resHeader res "retry-after"
    pure (st == 429 && vstring ra == "3")

  runTest c "feature.netsim_inactive_does_not_wrap" $ do
    nopts <- jo [("active", VBool False), ("offline", VBool True)]
    h <- makeClientH [("netsim", nopts)] Nothing []
    res <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "netsim"
    pure (orOk res && isNoval bucket)

  ---------------------------------------------------------------- retry
  runTest c "feature.retry_retries_transient_then_succeeds" $ do
    clk <- makeClock
    nopts <- jo [("failTimes", VNum 2), ("failStatus", VNum 503)]
    ropts <- jo [("retries", VNum 3), ("minDelay", VNum 10), ("jitter", VBool False), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("netsim", nopts), ("retry", ropts)] Nothing []
    res <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "retry"
    attempts <- bnum bucket "attempts"
    pure (orOk res && attempts == 2)

  runTest c "feature.retry_gives_up_after_budget" $ do
    clk <- makeClock
    nopts <- jo [("failTimes", VNum 9), ("failStatus", VNum 500)]
    ropts <- jo [("retries", VNum 2), ("minDelay", VNum 1), ("jitter", VBool False), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("netsim", nopts), ("retry", ropts)] Nothing []
    res <- runOpH h defaultOpArgs
    st <- resStatus res
    pure (st == 500)

  runTest c "feature.retry_does_not_retry_non_retryable_status" $ do
    let reply _ _ = do r <- makeResponse 404 VNoval []; pure (r, Nothing)
    (srv, calls) <- recordingServer (Just reply)
    ropts <- jo [("retries", VNum 3), ("minDelay", VNum 0)]
    h <- makeClientH [("retry", ropts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    cs <- readIORef calls
    pure (length cs == 1)

  runTest c "feature.retry_retries_transport_error_then_returns_it" $ do
    clk <- makeClock
    n <- newIORef (0 :: Int)
    let srv _ _ _ = do modifyIORef n (+ 1); e <- mkErr "boom" "boom"; pure (VNoval, Just e)
    ropts <- jo [("retries", VNum 2), ("minDelay", VNum 1), ("jitter", VBool False), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("retry", ropts)] (Just srv) []
    res <- runOpH h defaultOpArgs
    cnt <- readIORef n
    pure (not (orOk res) && cnt == 3)

  runTest c "feature.retry_retries_nil_transport_result" $ do
    n <- newIORef (0 :: Int)
    let srv _ _ _ = do
          modifyIORef n (+ 1); c0 <- readIORef n
          if c0 < 2 then pure (VNoval, Nothing)
          else do d <- jo [("ok", VBool True)]; r <- makeResponse 200 d []; pure (r, Nothing)
    ropts <- jo [("retries", VNum 3), ("minDelay", VNum 0)]
    h <- makeClientH [("retry", ropts)] (Just srv) []
    res <- runOpH h defaultOpArgs
    cnt <- readIORef n
    pure (orOk res && cnt == 2)

  runTest c "feature.retry_honours_server_retry_after" $ do
    clk <- makeClock
    nopts <- jo [("rateLimitTimes", VNum 1), ("retryAfter", VNum 2)]
    ropts <- jo [("retries", VNum 2), ("minDelay", VNum 10), ("maxDelay", VNum 60000), ("jitter", VBool False), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("netsim", nopts), ("retry", ropts)] Nothing []
    res <- runOpH h defaultOpArgs
    t <- clockNow clk
    pure (orOk res && t == 2000)

  runTest c "feature.retry_inactive_does_not_wrap" $ do
    let reply _ _ = do r <- makeResponse 503 VNoval []; pure (r, Nothing)
    (srv, calls) <- recordingServer (Just reply)
    ropts <- jo [("active", VBool False)]
    h <- makeClientH [("retry", ropts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    cs <- readIORef calls
    pure (length cs == 1)

  ---------------------------------------------------------------- timeout
  runTest c "feature.timeout_slow_request_times_out" $ do
    clk <- makeClock
    let srv _ _ _ = do clockAdvance clk 100; d <- jo [("ok", VBool True)]; r <- makeResponse 200 d []; pure (r, Nothing)
    topts <- jo [("ms", VNum 10), ("now", clockNowFn clk)]
    h <- makeClientH [("timeout", topts)] (Just srv) []
    res <- runOpH h defaultOpArgs
    ecode <- case orErr res of Just e -> errCode e; Nothing -> pure ""
    bucket <- trackGet (hClient h) "timeout"
    count <- bnum bucket "count"
    pure (not (orOk res) && ecode == "timeout" && count == 1)

  runTest c "feature.timeout_fast_request_passes" $ do
    clk <- makeClock
    topts <- jo [("ms", VNum 1000), ("now", clockNowFn clk)]
    h <- makeClientH [("timeout", topts)] Nothing []
    res <- runOpH h defaultOpArgs
    pure (orOk res)

  runTest c "feature.timeout_ms_zero_disables" $ do
    clk <- makeClock
    let srv _ _ _ = do clockAdvance clk 100; d <- jo [("ok", VBool True)]; r <- makeResponse 200 d []; pure (r, Nothing)
    topts <- jo [("ms", VNum 0), ("now", clockNowFn clk)]
    h <- makeClientH [("timeout", topts)] (Just srv) []
    res <- runOpH h defaultOpArgs
    pure (orOk res)

  runTest c "feature.timeout_inactive_does_not_wrap" $ do
    topts <- jo [("active", VBool False)]
    h <- makeClientH [("timeout", topts)] Nothing []
    res <- runOpH h defaultOpArgs
    pure (orOk res)

  ---------------------------------------------------------------- ratelimit
  runTest c "feature.ratelimit_throttles_once_burst_spent" $ do
    clk <- makeClock
    ropts <- jo [("rate", VNum 1), ("burst", VNum 2), ("now", clockNowFn clk), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("ratelimit", ropts)] Nothing []
    _ <- runOpH h defaultOpArgs
    _ <- runOpH h defaultOpArgs
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "ratelimit"
    throttled <- bnum bucket "throttled"
    t <- clockNow clk
    pure (throttled == 1 && t > 0)

  runTest c "feature.ratelimit_burst_defaults_to_rate_and_refills" $ do
    clk <- makeClock
    ropts <- jo [("rate", VNum 2), ("now", clockNowFn clk), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("ratelimit", ropts)] Nothing []
    _ <- runOpH h defaultOpArgs
    _ <- runOpH h defaultOpArgs
    clockAdvance clk 1000
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "ratelimit"
    throttled <- bnum bucket "throttled"
    pure (isNoval bucket || throttled == 0)

  runTest c "feature.ratelimit_inactive_does_not_wrap" $ do
    ropts <- jo [("active", VBool False)]
    h <- makeClientH [("ratelimit", ropts)] Nothing []
    res <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "ratelimit"
    pure (orOk res && isNoval bucket)

  ---------------------------------------------------------------- cache
  runTest c "feature.cache_serves_repeated_read_from_cache" $ do
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("ttl", VNum 10000)]
    h <- makeClientH [("cache", copts)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w/1" })
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w/1" })
    bucket <- trackGet (hClient h) "cache"
    hit <- bnum bucket "hit"
    cs <- readIORef calls
    pure (length cs == 1 && hit == 1)

  runTest c "feature.cache_does_not_cache_non_get" $ do
    (srv, calls) <- recordingServer Nothing
    h <- makeClientH [("cache", VNoval)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaOp = "create", oaMethod = Just "POST", oaPath = Just "/w" })
    _ <- runOpH h (defaultOpArgs { oaOp = "create", oaMethod = Just "POST", oaPath = Just "/w" })
    cs <- readIORef calls
    pure (length cs == 2)

  runTest c "feature.cache_does_not_cache_non_2xx" $ do
    let reply _ _ = do r <- makeResponse 500 VNoval []; pure (r, Nothing)
    (srv, calls) <- recordingServer (Just reply)
    h <- makeClientH [("cache", VNoval)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w" })
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w" })
    cs <- readIORef calls
    bucket <- trackGet (hClient h) "cache"
    bypass <- bnum bucket "bypass"
    pure (length cs == 2 && bypass == 2)

  runTest c "feature.cache_refetches_after_ttl" $ do
    clk <- makeClock
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("ttl", VNum 1000), ("now", clockNowFn clk)]
    h <- makeClientH [("cache", copts)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w" })
    clockAdvance clk 1500
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w" })
    cs <- readIORef calls
    pure (length cs == 2)

  runTest c "feature.cache_evicts_oldest_past_max" $ do
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("ttl", VNum 10000), ("max", VNum 1)]
    h <- makeClientH [("cache", copts)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/a" })
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/b" })
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/a" })
    cs <- readIORef calls
    pure (length cs == 3)

  runTest c "feature.cache_inactive_does_not_wrap" $ do
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("active", VBool False)]
    h <- makeClientH [("cache", copts)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/x" })
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/x" })
    cs <- readIORef calls
    pure (length cs == 2)

  ---------------------------------------------------------------- idempotency
  runTest c "feature.idempotency_adds_key_to_mutating_ops" $ do
    h <- makeClientH [("idempotency", VNoval)] Nothing []
    res <- runOpH h (defaultOpArgs { oaOp = "create", oaMethod = Just "POST" })
    k <- specHeader res "Idempotency-Key"
    bucket <- trackGet (hClient h) "idempotency"
    issued <- bnum bucket "issued"
    pure (not (isNoval k) && issued == 1)

  runTest c "feature.idempotency_adds_key_by_http_method" $ do
    h <- makeClientH [("idempotency", VNoval)] Nothing []
    res <- runOpH h (defaultOpArgs { oaOp = "act", oaMethod = Just "PUT" })
    k <- specHeader res "Idempotency-Key"
    pure (not (isNoval k))

  runTest c "feature.idempotency_leaves_reads_untouched" $ do
    h <- makeClientH [("idempotency", VNoval)] Nothing []
    res <- runOpH h defaultOpArgs
    k <- specHeader res "Idempotency-Key"
    pure (isNoval k)

  runTest c "feature.idempotency_preserves_caller_key_custom_header" $ do
    iopts <- jo [("header", VStr "X-Idem")]
    h <- makeClientH [("idempotency", iopts)] Nothing [("X-Idem", VStr "caller-1")]
    res <- runOpH h (defaultOpArgs { oaOp = "create", oaMethod = Just "POST" })
    k <- specHeader res "X-Idem"
    pure (vstring k == "caller-1")

  runTest c "feature.idempotency_injected_keygen" $ do
    iopts <- jo [("keygen", vfunc0 (pure (VStr "K1")))]
    h <- makeClientH [("idempotency", iopts)] Nothing []
    res <- runOpH h (defaultOpArgs { oaOp = "create", oaMethod = Just "POST" })
    k <- specHeader res "Idempotency-Key"
    bucket <- trackGet (hClient h) "idempotency"
    issued <- bnum bucket "issued"; lastK <- getp bucket "last"
    pure (vstring k == "K1" && issued == 1 && vstring lastK == "K1")

  runTest c "feature.idempotency_inactive_is_noop" $ do
    iopts <- jo [("active", VBool False)]
    h <- makeClientH [("idempotency", iopts)] Nothing []
    res <- runOpH h (defaultOpArgs { oaOp = "create", oaMethod = Just "POST" })
    k <- specHeader res "Idempotency-Key"
    pure (isNoval k)

  ---------------------------------------------------------------- rbac
  runTest c "feature.rbac_denies_before_any_call" $ do
    rules <- jo [("widget.remove", VStr "admin")]
    perms <- emptyList
    ropts <- jo [("rules", rules), ("permissions", perms)]
    (srv, calls) <- recordingServer Nothing
    h <- makeClientH [("rbac", ropts)] (Just srv) []
    res <- runOpH h (defaultOpArgs { oaOp = "remove", oaMethod = Just "DELETE" })
    ecode <- case orErr res of Just e -> errCode e; Nothing -> pure ""
    cs <- readIORef calls
    bucket <- trackGet (hClient h) "rbac"
    denied <- bnum bucket "denied"
    pure (not (orOk res) && ecode == "rbac_denied" && length cs == 0 && denied == 1)

  runTest c "feature.rbac_allows_held_permission" $ do
    rules <- jo [("widget.remove", VStr "admin")]
    perms <- ja [VStr "admin"]
    ropts <- jo [("rules", rules), ("permissions", perms)]
    h <- makeClientH [("rbac", ropts)] Nothing []
    res <- runOpH h (defaultOpArgs { oaOp = "remove", oaMethod = Just "DELETE" })
    bucket <- trackGet (hClient h) "rbac"
    allowed <- bnum bucket "allowed"
    pure (orOk res && allowed == 1)

  runTest c "feature.rbac_op_rule_and_wildcard_grant" $ do
    rules <- jo [("load", VStr "read")]
    perms <- ja [VStr "*"]
    ropts <- jo [("rules", rules), ("permissions", perms)]
    h <- makeClientH [("rbac", ropts)] Nothing []
    res <- runOpH h defaultOpArgs
    pure (orOk res)

  runTest c "feature.rbac_default_allow_and_deny_true" $ do
    permsA <- emptyList
    aopts <- jo [("permissions", permsA)]
    ha <- makeClientH [("rbac", aopts)] Nothing []
    ra <- runOpH ha defaultOpArgs
    permsD <- emptyList
    dopts <- jo [("deny", VBool True), ("permissions", permsD)]
    hd <- makeClientH [("rbac", dopts)] Nothing []
    rd <- runOpH hd defaultOpArgs
    ecode <- case orErr rd of Just e -> errCode e; Nothing -> pure ""
    pure (orOk ra && not (orOk rd) && ecode == "rbac_denied")

  runTest c "feature.rbac_inactive_is_noop" $ do
    ropts <- jo [("active", VBool False), ("deny", VBool True)]
    h <- makeClientH [("rbac", ropts)] Nothing []
    res <- runOpH h defaultOpArgs
    pure (orOk res)

  ---------------------------------------------------------------- metrics
  runTest c "feature.metrics_counts_ok_and_err_per_op" $ do
    nopts <- jo [("failTimes", VNum 1), ("failStatus", VNum 500)]
    h <- makeClientH [("netsim", nopts), ("metrics", VNoval)] Nothing []
    _ <- runOpH h defaultOpArgs
    _ <- runOpH h defaultOpArgs
    _ <- runOpH h (defaultOpArgs { oaOp = "list" })
    bucket <- trackGet (hClient h) "metrics"
    total <- getp bucket "total"
    count <- bnum total "count"; okN <- bnum total "ok"; errN <- bnum total "err"
    ops <- getp bucket "ops"; wl <- getp ops "widget.load"; wlCount <- bnum wl "count"
    pure (count == 3 && okN == 2 && errN == 1 && wlCount == 2)

  runTest c "feature.metrics_injected_clock" $ do
    clk <- makeClock
    mopts <- jo [("now", clockNowFn clk)]
    h <- makeClientH [("metrics", mopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "metrics"
    total <- getp bucket "total"
    count <- bnum total "count"; totalMs <- bnum total "totalMs"
    pure (count == 1 && totalMs == 0)

  runTest c "feature.metrics_inactive_records_nothing" $ do
    mopts <- jo [("active", VBool False)]
    h <- makeClientH [("metrics", mopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "metrics"
    total <- getp bucket "total"; count <- bnum total "count"
    pure (count == 0)

  ---------------------------------------------------------------- telemetry
  runTest c "feature.telemetry_opens_spans_and_propagates_headers" $ do
    exported <- newIORef ([] :: [Value])
    let exp0 = VFunc (\_ v _ _ -> do modifyIORef exported (++ [v]); pure VNoval)
    topts <- jo [("exporter", exp0)]
    h <- makeClientH [("telemetry", topts)] Nothing []
    res <- runOpH h defaultOpArgs
    tid <- specHeader res "X-Trace-Id"
    tp <- specHeader res "traceparent"
    bucket <- trackGet (hClient h) "telemetry"
    spans <- getp bucket "spans"; sps <- listVals spans
    span0 <- case sps of (s : _) -> pure s; [] -> pure VNoval
    spanTid <- getp span0 "traceId"
    exps <- readIORef exported
    let tps = vstring tp
    pure (length sps == 1 && length exps == 1 && vstring tid == vstring spanTid
          && startsWith "00-" tps && endsW "-01" tps)

  runTest c "feature.telemetry_records_failed_span" $ do
    nopts <- jo [("failTimes", VNum 1), ("failStatus", VNum 500)]
    h <- makeClientH [("netsim", nopts), ("telemetry", VNoval)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "telemetry"
    spans <- getp bucket "spans"; sps <- listVals spans
    span0 <- case sps of (s : _) -> pure s; [] -> pure VNoval
    okV <- getp span0 "ok"
    pure (length sps == 1 && not (isTrueV okV))

  runTest c "feature.telemetry_injected_idgen_and_clock" $ do
    clk <- makeClock
    topts <- jo [("idgen", vfnStr (++ "-X")), ("now", clockNowFn clk)]
    h <- makeClientH [("telemetry", topts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "telemetry"
    spans <- getp bucket "spans"; sps <- listVals spans
    span0 <- case sps of (s : _) -> pure s; [] -> pure VNoval
    tid <- getp span0 "traceId"; dur <- bnum span0 "durationMs"
    pure (vstring tid == "trace-X" && dur == 0)

  runTest c "feature.telemetry_inactive_records_nothing" $ do
    topts <- jo [("active", VBool False)]
    h <- makeClientH [("telemetry", topts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "telemetry"
    spans <- getp bucket "spans"; sps <- listVals spans
    pure (length sps == 0)

  ---------------------------------------------------------------- debug
  runTest c "feature.debug_redacts_and_honours_onentry_max" $ do
    seen <- newIORef ([] :: [Value])
    let onE = VFunc (\_ v _ _ -> do modifyIORef seen (++ [v]); pure VNoval)
    dopts <- jo [("max", VNum 1), ("onEntry", onE)]
    h <- makeClientH [("debug", dopts)] Nothing []
    _ <- runOpH h (defaultOpArgs { oaHeaders = [("authorization", VStr "Bearer secret")] })
    _ <- runOpH h (defaultOpArgs { oaOp = "list" })
    bucket <- trackGet (hClient h) "debug"
    entries <- getp bucket "entries"; es <- listVals entries
    ss <- readIORef seen
    e0 <- case ss of (s : _) -> pure s; [] -> pure VNoval
    hdrs <- getp e0 "headers"; auth <- getp hdrs "authorization"
    pure (length es == 1 && length ss == 2 && vstring auth == "<redacted>")

  runTest c "feature.debug_captures_failures" $ do
    nopts <- jo [("failTimes", VNum 1), ("failStatus", VNum 500)]
    h <- makeClientH [("netsim", nopts), ("debug", VNoval)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "debug"
    entries <- getp bucket "entries"; es <- listVals entries
    e0 <- case es of (s : _) -> pure s; [] -> pure VNoval
    okV <- getp e0 "ok"
    pure (length es == 1 && not (isTrueV okV))

  runTest c "feature.debug_injected_clock_and_custom_redact" $ do
    clk <- makeClock
    rl <- ja [VStr "x-secret"]
    dopts <- jo [("now", clockNowFn clk), ("redact", rl)]
    h <- makeClientH [("debug", dopts)] Nothing []
    _ <- runOpH h (defaultOpArgs { oaHeaders = [("x-secret", VStr "hide"), ("x-ok", VStr "show")] })
    bucket <- trackGet (hClient h) "debug"
    entries <- getp bucket "entries"; es <- listVals entries
    e0 <- case es of (s : _) -> pure s; [] -> pure VNoval
    hdrs <- getp e0 "headers"; sec <- getp hdrs "x-secret"; okh <- getp hdrs "x-ok"
    pure (vstring sec == "<redacted>" && vstring okh == "show")

  runTest c "feature.debug_inactive_records_nothing" $ do
    dopts <- jo [("active", VBool False)]
    h <- makeClientH [("debug", dopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "debug"
    entries <- getp bucket "entries"; es <- listVals entries
    pure (length es == 0)

  ---------------------------------------------------------------- audit
  runTest c "feature.audit_one_record_per_op_sink_actor" $ do
    sunk <- newIORef ([] :: [Value])
    let sink = VFunc (\_ v _ _ -> do modifyIORef sunk (++ [v]); pure VNoval)
    nopts <- jo [("failTimes", VNum 1), ("failStatus", VNum 500)]
    aopts <- jo [("actor", VStr "svc"), ("max", VNum 5), ("sink", sink)]
    h <- makeClientH [("netsim", nopts), ("audit", aopts)] Nothing []
    _ <- runOpH h (defaultOpArgs { oaOp = "remove", oaMethod = Just "DELETE" })
    perCall <- jo [("actor", VStr "per-call")]
    _ <- runOpH h (defaultOpArgs { oaCtrl = perCall })
    bucket <- trackGet (hClient h) "audit"
    recs <- getp bucket "records"; rs <- listVals recs
    r0 <- case rs of (x : _) -> pure x; [] -> pure VNoval
    r1 <- case rs of (_ : x : _) -> pure x; _ -> pure VNoval
    outcome0 <- getp r0 "outcome"; actor0 <- getp r0 "actor"; actor1 <- getp r1 "actor"
    ss <- readIORef sunk
    pure (length rs == 2 && vstring outcome0 == "error" && vstring actor0 == "svc"
          && vstring actor1 == "per-call" && length ss == 2)

  runTest c "feature.audit_default_actor_anonymous" $ do
    h <- makeClientH [("audit", VNoval)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "audit"
    recs <- getp bucket "records"; rs <- listVals recs
    r0 <- case rs of (x : _) -> pure x; [] -> pure VNoval
    actor <- getp r0 "actor"
    pure (vstring actor == "anonymous")

  runTest c "feature.audit_injected_clock" $ do
    aopts <- jo [("now", vfunc0 (pure (VNum 42)))]
    h <- makeClientH [("audit", aopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "audit"
    recs <- getp bucket "records"; rs <- listVals recs
    r0 <- case rs of (x : _) -> pure x; [] -> pure VNoval
    ts <- bnum r0 "ts"
    pure (ts == 42)

  runTest c "feature.audit_inactive_records_nothing" $ do
    aopts <- jo [("active", VBool False)]
    h <- makeClientH [("audit", aopts)] Nothing []
    _ <- runOpH h defaultOpArgs
    bucket <- trackGet (hClient h) "audit"
    recs <- getp bucket "records"; rs <- listVals recs
    pure (length rs == 0)

  ---------------------------------------------------------------- clienttrack
  runTest c "feature.clienttrack_stable_id_unique_request_ids_ua" $ do
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("clientName", VStr "Acme"), ("clientVersion", VStr "2.0.0")]
    h <- makeClientH [("clienttrack", copts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    _ <- runOpH h defaultOpArgs
    ua0 <- recHeader calls 0 "User-Agent"
    cid0 <- recHeader calls 0 "X-Client-Id"; cid1 <- recHeader calls 1 "X-Client-Id"
    rid0 <- recHeader calls 0 "X-Request-Id"; rid1 <- recHeader calls 1 "X-Request-Id"
    bucket <- trackGet (hClient h) "clienttrack"
    reqs <- bnum bucket "requests"
    pure (vstring ua0 == "Acme/2.0.0" && vstring cid0 == vstring cid1
          && vstring rid0 /= vstring rid1 && reqs == 2)

  runTest c "feature.clienttrack_does_not_clobber_caller_ua" $ do
    (srv, calls) <- recordingServer Nothing
    h <- makeClientH [("clienttrack", VNoval)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaHeaders = [("User-Agent", VStr "mine")] })
    ua <- recHeader calls 0 "User-Agent"
    pure (vstring ua == "mine")

  runTest c "feature.clienttrack_injected_idgen_fixed_session" $ do
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("sessionId", VStr "S1"), ("idgen", vfnStr (++ "-1"))]
    h <- makeClientH [("clienttrack", copts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    cid <- recHeader calls 0 "X-Client-Id"
    rid <- recHeader calls 0 "X-Request-Id"
    pure (vstring cid == "S1" && vstring rid == "request-1")

  runTest c "feature.clienttrack_inactive_stamps_nothing" $ do
    (srv, calls) <- recordingServer Nothing
    copts <- jo [("active", VBool False)]
    h <- makeClientH [("clienttrack", copts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    cid <- recHeader calls 0 "X-Client-Id"
    pure (isNoval cid)

  ---------------------------------------------------------------- paging
  runTest c "feature.paging_stamps_page_limit_and_reads_headers" $ do
    let reply _ _ = do
          d <- do a <- ja [VNum 1, VNum 2]; jo [("items", a)]
          makeResponse 200 d [("x-next-page", VStr "2"), ("x-total-count", VStr "5"), ("link", VStr "</w?page=2>; rel=\"next\"")]
            >>= \r -> pure (r, Nothing)
    (srv, calls) <- recordingServer (Just reply)
    popts <- jo [("limit", VNum 2)]
    h <- makeClientH [("paging", popts)] (Just srv) []
    res <- runOpH h (defaultOpArgs { oaOp = "list", oaPath = Just "/w" })
    u0 <- recUrl calls 0
    paging <- getp (orResult res) "paging"
    np <- bnum paging "nextPage"; tc <- bnum paging "totalCount"; nx <- getp paging "next"
    pure (substrContains u0 "page=1" && substrContains u0 "limit=2"
          && np == 2 && tc == 5 && vstring nx == "/w?page=2")

  runTest c "feature.paging_body_cursor_and_explicit_cursor" $ do
    let reply _ _ = do
          d <- jo [("nextCursor", VStr "abc"), ("hasMore", VBool True)]
          makeResponse 200 d [] >>= \r -> pure (r, Nothing)
    (srv, calls) <- recordingServer (Just reply)
    pg <- jo [("cursor", VStr "xyz")]
    ctrl <- jo [("paging", pg)]
    h <- makeClientH [("paging", VNoval)] (Just srv) []
    res <- runOpH h (defaultOpArgs { oaOp = "list", oaPath = Just "/w", oaCtrl = ctrl })
    u0 <- recUrl calls 0
    paging <- getp (orResult res) "paging"
    cur <- getp paging "cursor"; hm <- getp paging "hasMore"
    pure (substrContains u0 "cursor=xyz" && vstring cur == "abc" && isTrueV hm)

  runTest c "feature.paging_non_list_not_paged" $ do
    (srv, calls) <- recordingServer Nothing
    h <- makeClientH [("paging", VNoval)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaPath = Just "/w/1" })
    u0 <- recUrl calls 0
    pure (not (substrContains u0 "page="))

  runTest c "feature.paging_inactive_stamps_nothing" $ do
    (srv, calls) <- recordingServer Nothing
    popts <- jo [("active", VBool False)]
    h <- makeClientH [("paging", popts)] (Just srv) []
    _ <- runOpH h (defaultOpArgs { oaOp = "list", oaPath = Just "/w" })
    u0 <- recUrl calls 0
    pure (not (substrContains u0 "page="))

  ---------------------------------------------------------------- streaming
  runTest c "feature.streaming_streams_list_items" $ do
    clk <- makeClock
    let reply _ _ = do d <- ja [VStr "a", VStr "b", VStr "c"]; makeResponse 200 d [] >>= \r -> pure (r, Nothing)
    (srv, _) <- recordingServer (Just reply)
    sopts <- jo [("chunkDelay", VNum 5), ("sleep", clockSleepFn clk)]
    h <- makeClientH [("streaming", sopts)] (Just srv) []
    res <- runOpH h (defaultOpArgs { oaOp = "list", oaPath = Just "/w" })
    streaming <- getp (orResult res) "streaming"
    stream <- getp (orResult res) "stream"
    seen <- callVfn stream VNoval
    its <- listVals seen
    t <- clockNow clk
    pure (isTrueV streaming && map vstring its == ["a", "b", "c"] && t == 15)

  runTest c "feature.streaming_batches_with_chunksize" $ do
    let reply _ _ = do d <- ja [VNum 1, VNum 2, VNum 3, VNum 4, VNum 5]; makeResponse 200 d [] >>= \r -> pure (r, Nothing)
    (srv, _) <- recordingServer (Just reply)
    sopts <- jo [("chunkSize", VNum 2)]
    h <- makeClientH [("streaming", sopts)] (Just srv) []
    res <- runOpH h (defaultOpArgs { oaOp = "list", oaPath = Just "/w" })
    stream <- getp (orResult res) "stream"
    batches <- callVfn stream VNoval
    bs <- listVals batches
    lens <- mapM (\b -> length <$> listVals b) bs
    flat <- concat <$> mapM listVals bs
    pure (lens == [2, 2, 1] && map vstring flat == ["1", "2", "3", "4", "5"])

  runTest c "feature.streaming_non_list_not_streamed" $ do
    h <- makeClientH [("streaming", VNoval)] Nothing []
    res <- runOpH h defaultOpArgs
    streaming <- getp (orResult res) "streaming"
    stream <- getp (orResult res) "stream"
    pure (not (isTrueV streaming) && isNoval stream)

  runTest c "feature.streaming_inactive_is_noop" $ do
    let reply _ _ = do d <- ja [VStr "a"]; makeResponse 200 d [] >>= \r -> pure (r, Nothing)
    (srv, _) <- recordingServer (Just reply)
    sopts <- jo [("active", VBool False)]
    h <- makeClientH [("streaming", sopts)] (Just srv) []
    res <- runOpH h (defaultOpArgs { oaOp = "list", oaPath = Just "/w" })
    streaming <- getp (orResult res) "streaming"
    bucket <- trackGet (hClient h) "streaming"
    opened <- bnum bucket "opened"
    pure (not (isTrueV streaming) && (isNoval bucket || opened == 0))

  ---------------------------------------------------------------- proxy
  runTest c "feature.proxy_routes_through_proxy" $ do
    (srv, calls) <- recordingServer Nothing
    popts <- jo [("url", VStr "http://proxy:8080")]
    h <- makeClientH [("proxy", popts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    fd <- recFetchdef calls 0; px <- getp fd "proxy"
    bucket <- trackGet (hClient h) "proxy"; routed <- bnum bucket "routed"
    pure (vstring px == "http://proxy:8080" && routed == 1)

  runTest c "feature.proxy_bypasses_noproxy_hosts" $ do
    (srv, calls) <- recordingServer Nothing
    np <- ja [VStr "api.test"]
    popts <- jo [("url", VStr "http://proxy:8080"), ("noProxy", np)]
    h <- makeClientH [("proxy", popts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    fd <- recFetchdef calls 0; px <- getp fd "proxy"
    pure (isNoval px)

  runTest c "feature.proxy_fromenv_reads_https_proxy" $ do
    prev <- lookupEnv "HTTPS_PROXY"
    setEnv "HTTPS_PROXY" "http://env-proxy:8080"
    (srv, calls) <- recordingServer Nothing
    popts <- jo [("fromEnv", VBool True)]
    h <- makeClientH [("proxy", popts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    case prev of Just v -> setEnv "HTTPS_PROXY" v; Nothing -> unsetEnv "HTTPS_PROXY"
    fd <- recFetchdef calls 0; px <- getp fd "proxy"
    pure (vstring px == "http://env-proxy:8080")

  runTest c "feature.proxy_no_url_is_noop" $ do
    (srv, calls) <- recordingServer Nothing
    h <- makeClientH [("proxy", VNoval)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    fd <- recFetchdef calls 0; px <- getp fd "proxy"
    pure (isNoval px)

  runTest c "feature.proxy_inactive_does_not_wrap" $ do
    (srv, calls) <- recordingServer Nothing
    popts <- jo [("active", VBool False), ("url", VStr "http://proxy:8080")]
    h <- makeClientH [("proxy", popts)] (Just srv) []
    _ <- runOpH h defaultOpArgs
    fd <- recFetchdef calls 0; px <- getp fd "proxy"
    pure (isNoval px)

  ---------------------------------------------------------------- composition
  runTest c "feature.composition_cache_hit_skips_simulated_failure" $ do
    nopts <- jo [("failEvery", VNum 2)]
    copts <- jo [("ttl", VNum 10000)]
    h <- makeClientH [("netsim", nopts), ("cache", copts)] Nothing []
    r1 <- runOpH h (defaultOpArgs { oaPath = Just "/w" })
    r2 <- runOpH h (defaultOpArgs { oaPath = Just "/w" })
    bucket <- trackGet (hClient h) "netsim"
    calls <- bnum bucket "calls"
    pure (orOk r1 && orOk r2 && calls == 1)
