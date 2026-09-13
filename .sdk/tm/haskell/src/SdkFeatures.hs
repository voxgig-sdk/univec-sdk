-- Univec SDK features + API-agnostic client helpers.
--
-- The 18 pipeline features (base/test/log + the 15 enterprise features) and
-- the transport they wrap, plus make_client_base / direct / prepare / test and
-- the generic (config-driven) entity constructor. Each feature is built by an
-- IO constructor that allocates IORefs for its mutable state and returns a
-- `Feature` whose init/hook closures observe and mutate the shared pipeline
-- state. Transport-wrapping features re-bind the mutable `uFetcher` cell so
-- later inits sit outermost.

module SdkFeatures where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO, try)
import Control.Monad (forM_, when)
import Data.Bits ((.&.))
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Environment (lookupEnv)

import VoxgigStruct
  ( Value (..), InjArg (..), emptyList, emptyMap, mkList
  , getprop, setprop, delprop, getelem, keysof, listItems
  , clone, merge, transform, select, size, isempty, ismap, isNoval, isNullish
  , vint, setpath, walk )
import SdkTypes
import SdkHelpers
import SdkRuntime

-- ------------------------------------------------------------------
-- clock / option readers
-- ------------------------------------------------------------------

defaultNowMs :: IO Double
defaultNowMs = (* 1000) . realToFrac <$> getPOSIXTime

realSleep :: Double -> IO ()
realSleep ms = when (ms > 0) (threadDelay (round (ms * 1000)))

optNum :: Value -> String -> Double -> IO Double
optNum opts k d = do v <- getp opts k; pure (case v of VNum n -> n; _ -> d)

optInt :: Value -> String -> Int -> IO Int
optInt opts k d = do v <- getp opts k; pure (case v of VNum n -> truncate n; _ -> d)

optStr :: Value -> String -> String -> IO String
optStr = getStrD

optActive :: Value -> IO Bool
optActive opts = isTrueV <$> getp opts "active"

optStrList :: Value -> String -> [String] -> IO [String]
optStrList opts k d = do
  v <- getp opts k
  case v of { VList _ -> do { its <- listItems v; pure [s | VStr s <- its] }; _ -> pure d }

nowOf :: Value -> IO Double
nowOf opts = do
  v <- getp opts "now"
  case v of
    VFunc _ -> do r <- callVfn v VNoval; pure (case r of VNum n -> n; _ -> 0)
    _ -> defaultNowMs

sleepOf :: Value -> Double -> IO ()
sleepOf opts ms = when (ms > 0) $ do
  v <- getp opts "sleep"
  case v of VFunc _ -> () <$ callVfn v (VNum ms); _ -> realSleep ms

toOptsMap :: Value -> IO Value
toOptsMap opts = case toMap opts of VMap _ -> pure opts; _ -> emptyMap

-- ------------------------------------------------------------------
-- small helpers
-- ------------------------------------------------------------------

endsWith :: String -> String -> Bool
endsWith s suf = length s >= length suf && drop (length s - length suf) s == suf

stripLeadDot :: String -> String
stripLeadDot ('.' : r) = r
stripLeadDot s = s

urlHost :: String -> String
urlHost url = case findScheme 0 of
  Just start -> takeWhile (\c -> c /= '/' && c /= ':') (drop start url)
  Nothing -> url
  where
    n = length url
    findScheme i
      | i + 3 > n = Nothing
      | take 3 (drop i url) == "://" = Just (i + 3)
      | otherwise = findScheme (i + 1)

featureBase :: IO (IORef Bool, IORef Value)
featureBase = do active <- newIORef True; fopts <- newIORef VNoval; pure (active, fopts)

-- ------------------------------------------------------------------
-- base / log
-- ------------------------------------------------------------------

baseFeature :: IO Feature
baseFeature = do
  (active, fopts) <- featureBase
  pure Feature { fName = "base", fVersion = "0.0.1", fActive = active, fOptions = fopts
               , fInit = \_ _ -> pure (), fHook = \_ _ -> pure () }

logFeature :: IO Feature
logFeature = do
  (active, fopts) <- featureBase
  let initFn _ opts = do a <- optActive opts; writeIORef active a
  pure Feature { fName = "log", fVersion = "0.0.1", fActive = active, fOptions = fopts
               , fInit = initFn, fHook = \_ _ -> pure () }

-- ------------------------------------------------------------------
-- retry
-- ------------------------------------------------------------------

retryFeature :: IO Feature
retryFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let statuses = do
        opts <- readIORef options; v <- getp opts "statuses"
        case v of { VList _ -> do { its <- listItems v; pure [truncate n | VNum n <- its] }; _ -> pure [408, 425, 429, 500, 502, 503, 504] }
      retryAfterOf resV = case resV of
        VMap _ -> do
          h <- getp resV "headers"
          case h of
            VMap _ -> do
              ra <- headerCI h "retry-after"
              case ra of
                VNoval -> pure Nothing; VNull -> pure Nothing
                _ -> case reads (vstring ra) :: [(Double, String)] of { [(x, _)] -> pure (Just (x * 1000)); _ -> pure Nothing }
            _ -> pure Nothing
        _ -> pure Nothing
      retryable resV merr =
        if isJust merr then pure True
        else if isNoval resV then pure True
        else case resV of { VMap _ -> do { st <- getp resV "status"; sts <- statuses; pure (case st of { VNum n -> truncate n `elem` sts; _ -> False }) }; _ -> pure False }
      backoff resV attempt = do
        opts <- readIORef options
        minDelay <- optNum opts "minDelay" 50; maxDelay <- optNum opts "maxDelay" 2000; factor <- optNum opts "factor" 2
        ra <- retryAfterOf resV
        case ra of
          Just r -> pure (min maxDelay r)
          Nothing -> do
            let base = minDelay * (factor ^^ attempt)
            jv <- getp opts "jitter"
            jitter <- case jv of VBool False -> pure 0; _ -> do j <- randInt (max 1 (round minDelay)); pure (fromIntegral j)
            pure (min maxDelay (base + jitter))
      track ctx = do cl <- cc ctx; bucket <- trackBucket cl "retry" (do rs <- emptyList; jo [("attempts", VNum 0), ("retries", rs)]); bumpNum bucket "attempts" 1
      withRetry ctx url fd inner = do
        opts <- readIORef options
        retries <- optInt opts "retries" 2
        let loop attempt = do
              (r, e) <- inner ctx url fd
              ret <- retryable r e
              if not ret || attempt >= retries then pure (r, e)
              else do w <- backoff r attempt; track ctx; sleepOf opts w; loop (attempt + 1)
        loop 0
      initFn ctx opts = do
        om <- toOptsMap opts; writeIORef options om
        a <- optActive opts; writeIORef active a
        when a $ do u <- cu ctx; inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\c ur f -> withRetry c ur f inner)
  pure Feature { fName = "retry", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

-- ------------------------------------------------------------------
-- timeout
-- ------------------------------------------------------------------

timeoutFeature :: IO Feature
timeoutFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let track ctx ms = do cl <- cc ctx; bucket <- trackBucket cl "timeout" (jo [("count", VNum 0), ("ms", VNum ms)]); bumpNum bucket "count" 1
      withTimeout ctx url fd inner = do
        opts <- readIORef options
        ms <- optNum opts "ms" 30000
        if ms <= 0 then inner ctx url fd
        else do
          fdC <- clone fd
          fd2 <- case fdC of VMap _ -> pure fdC; _ -> emptyMap
          setp fd2 "timeout" (VNum (ms / 1000))
          start <- nowOf opts
          (res, err) <- inner ctx url fd2
          now <- nowOf opts
          let elapsed = now - start
          if elapsed > ms
            then do track ctx ms; e <- mkErr "timeout" ("Request exceeded timeout of " ++ show (truncate ms :: Int) ++ "ms"); pure (VNoval, Just e)
            else pure (res, err)
      initFn ctx opts = do
        om <- toOptsMap opts; writeIORef options om
        a <- optActive opts; writeIORef active a
        when a $ do u <- cu ctx; inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\c ur f -> withTimeout c ur f inner)
  pure Feature { fName = "timeout", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

-- ------------------------------------------------------------------
-- ratelimit
-- ------------------------------------------------------------------

ratelimitFeature :: IO Feature
ratelimitFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  tokens <- newIORef (0 :: Double)
  lastR <- newIORef (0 :: Double)
  let rateOf = do opts <- readIORef options; v <- getp opts "rate"; pure (case v of VNum n | n /= 0 -> n; _ -> 5)
      burstOf = do opts <- readIORef options; v <- getp opts "burst"; case v of VNum n -> pure n; _ -> rateOf
      track ctx wait = do cl <- cc ctx; bucket <- trackBucket cl "ratelimit" (jo [("throttled", VNum 0), ("waitMs", VNum 0)]); bumpNum bucket "throttled" 1; bumpNum bucket "waitMs" wait
      acquire ctx = do
        opts <- readIORef options
        r <- rateOf; b <- burstOf
        now <- nowOf opts
        lst <- readIORef lastR
        let elapsed = now - lst
        writeIORef lastR now
        tk <- readIORef tokens
        let tk' = min b (tk + (elapsed / 1000) * r)
        if tk' >= 1 then writeIORef tokens (tk' - 1)
        else do
          let needed = 1 - tk'
              waitMs = fromIntegral (ceiling ((needed / r) * 1000) :: Int)
          track ctx waitMs; sleepOf opts waitMs
          now2 <- nowOf opts; writeIORef lastR now2; writeIORef tokens 0
      initFn ctx opts = do
        om <- toOptsMap opts; writeIORef options om
        a <- optActive opts; writeIORef active a
        when a $ do
          b <- burstOf; writeIORef tokens b
          n0 <- nowOf =<< readIORef options; writeIORef lastR n0
          u <- cu ctx; inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\c ur f -> do acquire c; inner c ur f)
  pure Feature { fName = "ratelimit", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

-- ------------------------------------------------------------------
-- cache
-- ------------------------------------------------------------------

cacheFeature :: IO Feature
cacheFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  store <- newIORef ([] :: [(String, Value)])
  let track ctx kind = do cl <- cc ctx; bucket <- trackBucket cl "cache" (jo [("hit", VNum 0), ("miss", VNum 0), ("bypass", VNum 0)]); bumpNum bucket kind 1
      cacheable res = case res of { VMap _ -> do { st <- getp res "status"; pure (case st of { VNum n -> n >= 200 && n < 300; _ -> False }) }; _ -> pure False }
      snapshot res = do
        jv <- getp res "json"
        d <- case jv of VFunc _ -> callJson jv; _ -> pure VNoval
        headers <- emptyMap
        h <- getp res "headers"
        case h of { VMap _ -> do { ks <- keysof h; forM_ ks $ \k -> do { vv <- getp h k; setp headers (lower k) vv } }; _ -> pure () }
        st <- getp res "status"; stt <- getp res "statusText"
        jo [("status", st), ("statusText", stt), ("data", d), ("headers", headers)]
      replay snap = do
        d <- getp snap "data"; st <- getp snap "status"; stt <- getp snap "statusText"
        h <- getp snap "headers"; hC <- clone h; h2 <- case hC of VMap _ -> pure hC; _ -> emptyMap
        jo [("status", st), ("statusText", stt), ("body", VStr "not-used"), ("json", jsonThunk d), ("headers", h2)]
      evict = do opts <- readIORef options; mx <- optInt opts "max" 256; let go = do s <- readIORef store; when (length s >= mx) (case s of (_ : tl) -> writeIORef store tl >> go; [] -> pure ()) in go
      through ctx url fd inner = do
        opts <- readIORef options
        meth <- (\v -> case v of VStr s -> upper s; _ -> "GET") <$> getp fd "method"
        methods <- map upper <$> optStrList opts "methods" ["GET"]
        if meth `notElem` methods then inner ctx url fd
        else do
          let key = meth ++ " " ++ url
          now <- nowOf opts
          s <- readIORef store
          case lookup key s of
            Just hit -> do
              exp0 <- getp hit "expiry"
              let fresh = case exp0 of { VNum e -> e > now; _ -> False }
              if fresh then do track ctx "hit"; snp <- getp hit "snapshot"; rp <- replay snp; pure (rp, Nothing)
              else doMiss ctx url fd inner opts key now
            Nothing -> doMiss ctx url fd inner opts key now
      doMiss ctx url fd inner opts key now = do
        (res, err) <- inner ctx url fd
        ok <- cacheable res
        if isNothing err && ok
          then do
            snp <- snapshot res
            ttl <- optNum opts "ttl" 5000
            evict
            entry <- jo [("expiry", VNum (now + ttl)), ("snapshot", snp)]
            modifyIORef store (\st -> filter ((/= key) . fst) st ++ [(key, entry)])
            track ctx "miss"
            rp <- replay snp; pure (rp, Nothing)
          else do track ctx "bypass"; pure (res, err)
      initFn ctx opts = do
        om <- toOptsMap opts; writeIORef options om
        a <- optActive opts; writeIORef active a
        when a $ do writeIORef store []; u <- cu ctx; inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\c ur f -> through c ur f inner)
  pure Feature { fName = "cache", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

-- ------------------------------------------------------------------
-- idempotency
-- ------------------------------------------------------------------

idempotencyFeature :: IO Feature
idempotencyFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let genkey = do opts <- readIORef options; v <- getp opts "keygen"; case v of VFunc _ -> vstring <$> callVfn v VNoval; _ -> randId16
      mutating ctx = do
        opts <- readIORef options
        methods <- map upper <$> optStrList opts "methods" ["POST", "PUT", "PATCH", "DELETE"]
        specV <- readIORef (cSpec ctx)
        meth <- case specV of VMap _ -> upper <$> getStrD specV "method" ""; _ -> pure ""
        if meth /= "" && meth `elem` methods then pure True
        else do op <- readIORef (cOp ctx); ops <- optStrList opts "ops" ["create", "update", "remove"]; pure (opName op `elem` ops)
      hookFn name ctx = do
        a <- readIORef active
        when (name == "PreRequest" && a) $ do
          specV <- readIORef (cSpec ctx)
          case specV of
            VMap _ -> do
              mut <- mutating ctx
              when mut $ do
                opts <- readIORef options
                header <- optStr opts "header" "Idempotency-Key"
                hdrs <- getp specV "headers"
                existing <- headerCI hdrs header
                when (isNoval existing) $ do
                  key <- genkey
                  setp hdrs header (VStr key)
                  cl <- cc ctx
                  bucket <- trackBucket cl "idempotency" (jo [("issued", VNum 0), ("last", VNoval)])
                  bumpNum bucket "issued" 1; setp bucket "last" (VStr key)
            _ -> pure ()
      initFn _ opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a
  pure Feature { fName = "idempotency", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

-- ------------------------------------------------------------------
-- rbac (PrePoint short-circuit)
-- ------------------------------------------------------------------

rbacFeature :: IO Feature
rbacFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  perms <- newIORef ([] :: [String])
  let track ctx required allowed = do
        cl <- cc ctx
        bucket <- trackBucket cl "rbac" (jo [("allowed", VNum 0), ("denied", VNum 0), ("last", VNoval)])
        bumpNum bucket (if allowed then "allowed" else "denied") 1
        op <- readIORef (cOp ctx)
        lastM <- jo [("required", VStr required), ("allowed", VBool allowed), ("op", VStr (opName op))]
        setp bucket "last" lastM
      requiredOf ctx = do
        opts <- readIORef options
        rulesV <- getp opts "rules"
        let rules = case rulesV of { VMap _ -> rulesV; _ -> VNoval }
        ment <- readIORef (cEntity ctx); op <- readIORef (cOp ctx)
        let entity = case ment of Just e -> eName e; Nothing -> if opEntity op /= "" then opEntity op else ""
            opname = opName op
            ruleFor k = do v <- getp rules k; pure (case v of VNoval -> Nothing; VNull -> Nothing; _ -> Just (vstring v))
        r1 <- ruleFor (entity ++ "." ++ opname)
        case r1 of
          Just v -> pure (Just v)
          Nothing -> do r2 <- ruleFor opname; case r2 of Just v -> pure (Just v); Nothing -> ruleFor "*"
      reject ctx req = do
        track ctx req False
        op <- readIORef (cOp ctx)
        let opname = if opName op /= "" && opName op /= "_" then opName op else "?"
        e <- mkErr "rbac_denied" ("Permission \"" ++ req ++ "\" required for operation \"" ++ opname ++ "\"")
        out <- readIORef (cOut ctx); setp out "point" e
      hookFn name ctx = do
        a <- readIORef active
        when (name == "PrePoint" && a) $ do
          mreq <- requiredOf ctx
          case mreq of
            Nothing -> do opts <- readIORef options; d <- getp opts "deny"; when (isTrueV d) (reject ctx "<default-deny>")
            Just req -> do ps <- readIORef perms; if "*" `elem` ps || req `elem` ps then track ctx req True else reject ctx req
      initFn _ opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a; pl <- optStrList om "permissions" []; writeIORef perms pl
  pure Feature { fName = "rbac", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

-- ------------------------------------------------------------------
-- metrics
-- ------------------------------------------------------------------

metricsFeature :: IO Feature
metricsFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let metrics ctx = do cl <- cc ctx; trackBucket cl "metrics" (do tot <- jo [("count", VNum 0), ("ok", VNum 0), ("err", VNum 0), ("totalMs", VNum 0), ("maxMs", VNum 0)]; ops <- emptyMap; jo [("total", tot), ("ops", ops)])
      bump b ok dur = do bumpNum b "count" 1; bumpNum b (if ok then "ok" else "err") 1; bumpNum b "totalMs" dur; mx <- getp b "maxMs"; let { m = case mx of { VNum n -> n; _ -> 0 } }; when (dur > m) (setp b "maxMs" (VNum dur))
      record ctx ok = do
        startV <- scratchGet ctx "metrics_start"
        case startV of
          VNum start -> do
            scratchDel ctx "metrics_start"
            opts <- readIORef options; now <- nowOf opts
            let dur = max 0 (now - start)
            m <- metrics ctx; op <- readIORef (cOp ctx)
            let key = opEntity op ++ "." ++ opName op
            ops <- getp m "ops"; opbV <- getp ops key
            opb <- case opbV of VMap _ -> pure opbV; _ -> do b <- jo [("count", VNum 0), ("ok", VNum 0), ("err", VNum 0), ("totalMs", VNum 0), ("maxMs", VNum 0)]; setp ops key b; pure b
            tot <- getp m "total"; bump tot ok dur; bump opb ok dur
          _ -> pure ()
      hookFn name ctx = do
        a <- readIORef active
        when a $ case name of
          "PrePoint" -> do opts <- readIORef options; now <- nowOf opts; scratchSet ctx "metrics_start" (VNum now)
          "PreDone" -> do ok <- resultOk ctx; record ctx ok
          "PreUnexpected" -> record ctx False
          _ -> pure ()
      initFn ctx opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a; _ <- metrics ctx; pure ()
  pure Feature { fName = "metrics", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

resultOk :: Context -> IO Bool
resultOk ctx = do
  rv <- readIORef (cResult ctx)
  case rv of
    VMap _ -> do ok <- getp rv "ok"; err <- getp rv "err"; isE <- isErr err; pure (isTrueV ok && not isE)
    _ -> pure False

-- ------------------------------------------------------------------
-- telemetry
-- ------------------------------------------------------------------

telemetryFeature :: IO Feature
telemetryFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  seqR <- newIORef (0 :: Int)
  let telemetry ctx = do cl <- cc ctx; trackBucket cl "telemetry" (do sp <- emptyList; jo [("spans", sp), ("active", VNum 0)])
      genId kind = do
        opts <- readIORef options; v <- getp opts "idgen"
        case v of
          VFunc _ -> vstring <$> callVfn v (VStr kind)
          _ -> do modifyIORef seqR (+ 1); s <- readIORef seqR; let { n = pad4 s; padded = n ++ replicate (max 0 (16 - length n)) '0' }; pure ((if kind == "trace" then "t" else "s") ++ padded)
      close ctx ok = do
        spanV <- scratchGet ctx "telemetry_span"
        case spanV of
          VMap _ -> do
            scratchDel ctx "telemetry_span"
            opts <- readIORef options; end <- nowOf opts
            setp spanV "end" (VNum end)
            start <- getp spanV "start"; let s = case start of { VNum n -> n; _ -> 0 }
            setp spanV "durationMs" (VNum (max 0 (end - s)))
            setp spanV "ok" (VBool ok)
            t <- telemetry ctx; bumpNum t "active" (-1)
            spans <- getp t "spans"; appendList spans spanV
            expv <- getp opts "exporter"; case expv of VFunc _ -> () <$ callVfn expv spanV; _ -> pure ()
          _ -> pure ()
      hookFn name ctx = do
        a <- readIORef active
        when a $ case name of
          "PrePoint" -> do
            op <- readIORef (cOp ctx)
            let entity = if opEntity op /= "" then opEntity op else "_"
                opname = if opName op /= "" then opName op else "_"
            tid <- genId "trace"; sid <- genId "span"; opts <- readIORef options; now <- nowOf opts
            span0 <- jo [("traceId", VStr tid), ("spanId", VStr sid), ("name", VStr (entity ++ "." ++ opname)), ("start", VNum now), ("end", VNoval), ("durationMs", VNoval), ("ok", VNoval)]
            scratchSet ctx "telemetry_span" span0
            t <- telemetry ctx; bumpNum t "active" 1
          "PreRequest" -> do
            spanV <- scratchGet ctx "telemetry_span"; specV <- readIORef (cSpec ctx)
            case (spanV, specV) of
              (VMap _, VMap _) -> do
                opts <- readIORef options; hopt <- getp opts "headers"; let hget k d = case hopt of { VMap _ -> getStrD hopt k d; _ -> pure d }
                hdrs <- getp specV "headers"
                th <- hget "trace" "X-Trace-Id"; tid <- getp spanV "traceId"; setp hdrs th tid
                sh <- hget "span" "X-Span-Id"; sid <- getp spanV "spanId"; setp hdrs sh sid
                ph <- hget "parent" "traceparent"; setp hdrs ph (VStr ("00-" ++ vstring tid ++ "-" ++ vstring sid ++ "-01"))
              _ -> pure ()
          "PreDone" -> do ok <- resultOk ctx; close ctx ok
          "PreUnexpected" -> close ctx False
          _ -> pure ()
      initFn ctx opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a; writeIORef seqR 0; _ <- telemetry ctx; pure ()
  pure Feature { fName = "telemetry", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

pad4 :: Int -> String
pad4 n = let s = showHexLower n in replicate (max 0 (4 - length s)) '0' ++ s

showHexLower :: Int -> String
showHexLower 0 = "0"
showHexLower n = go n ""
  where go 0 acc = acc
        go x acc = go (x `div` 16) (hexDigit (x `mod` 16) : acc)
        hexDigit d = "0123456789abcdef" !! d

appendList :: Value -> Value -> IO ()
appendList lst v = do its <- listItems lst; new <- mkList (its ++ [v]); case lst of VList r -> writeIORef r =<< listItems new; _ -> pure ()

-- ------------------------------------------------------------------
-- debug
-- ------------------------------------------------------------------

debugFeature :: IO Feature
debugFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let debug ctx = do cl <- cc ctx; trackBucket cl "debug" (do es <- emptyList; jo [("entries", es)])
      redact headers = case headers of
        VMap _ -> do
          opts <- readIORef options
          patterns <- optStrList opts "redact" ["authorization", "cookie", "set-cookie", "api-key", "apikey", "x-api-key", "idempotency-key"]
          out <- emptyMap; ks <- keysof headers
          forM_ ks $ \k -> if lower k `elem` patterns then setp out k (VStr "<redacted>") else do v <- getp headers k; setp out k v
          pure out
        _ -> emptyMap
      finish ctx ok = do
        entryV <- scratchGet ctx "debug_entry"
        case entryV of
          VMap _ -> do
            scratchDel ctx "debug_entry"
            opts <- readIORef options
            rv <- readIORef (cResult ctx); rok <- case rv of VMap _ -> isTrueV <$> getp rv "ok"; _ -> pure True
            setp entryV "ok" (VBool (ok && rok))
            now <- nowOf opts; start <- getp entryV "start"; let s = case start of { VNum n -> n; _ -> 0 }
            setp entryV "durationMs" (VNum (max 0 (now - s)))
            st <- getp entryV "status"
            case st of VNoval -> case rv of { VMap _ -> do { rs <- getp rv "status"; setp entryV "status" rs }; _ -> pure () }; _ -> pure ()
            d <- debug ctx; buf <- getp d "entries"; appendList buf entryV
            mx <- optInt opts "max" 100
            trimList buf mx
            oe <- getp opts "onEntry"; case oe of VFunc _ -> () <$ callVfn oe entryV; _ -> pure ()
          _ -> pure ()
      hookFn name ctx = do
        a <- readIORef active
        when a $ case name of
          "PreRequest" -> do
            op <- readIORef (cOp ctx)
            let opname = (if opEntity op /= "" then opEntity op else "_") ++ "." ++ (if opName op /= "" then opName op else "_")
            specV <- readIORef (cSpec ctx)
            opts <- readIORef options; now <- nowOf opts
            (methodV, urlV, hdrs) <- case specV of
              VMap _ -> do m <- getp specV "method"; u0 <- getStrD specV "url" ""; p0 <- getStrD specV "path" ""; h <- getp specV "headers"; pure (m, VStr (if u0 /= "" then u0 else p0), h)
              _ -> pure (VNoval, VNoval, VNoval)
            rh <- redact hdrs
            entry <- jo [("op", VStr opname), ("method", methodV), ("url", urlV), ("headers", rh), ("start", VNum now), ("status", VNoval), ("ok", VNoval), ("durationMs", VNoval), ("error", VNoval)]
            scratchSet ctx "debug_entry" entry
          "PreResponse" -> do
            entryV <- scratchGet ctx "debug_entry"
            case entryV of
              VMap _ -> do
                respV <- readIORef (cResponse ctx)
                case respV of VMap _ -> do { rs <- getp respV "status"; setp entryV "status" rs }; _ -> pure ()
                u0 <- getp entryV "url"
                case u0 of
                  VNoval -> setUrlFromSpec ctx entryV
                  VStr "" -> setUrlFromSpec ctx entryV
                  _ -> pure ()
              _ -> pure ()
          "PreDone" -> finish ctx True
          "PreUnexpected" -> do
            entryV <- scratchGet ctx "debug_entry"
            case entryV of
              VMap _ -> do ctrl <- readIORef (cCtrl ctx); err <- getp ctrl "err"; isE <- isErr err; when isE (do m <- errMsg err; setp entryV "error" (VStr m))
              _ -> pure ()
            finish ctx False
          _ -> pure ()
      setUrlFromSpec ctx entryV = do specV <- readIORef (cSpec ctx); case specV of { VMap _ -> do { u <- getStrD specV "url" ""; when (u /= "") (setp entryV "url" (VStr u)) }; _ -> pure () }
      initFn ctx opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a; _ <- debug ctx; pure ()
  pure Feature { fName = "debug", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

trimList :: Value -> Int -> IO ()
trimList lst mx = do
  its <- listItems lst
  when (length its > mx) $ case lst of VList r -> writeIORef r (drop (length its - mx) its); _ -> pure ()

-- ------------------------------------------------------------------
-- audit
-- ------------------------------------------------------------------

auditFeature :: IO Feature
auditFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  seqR <- newIORef (0 :: Int)
  let audit ctx = do cl <- cc ctx; trackBucket cl "audit" (do rs <- emptyList; jo [("records", rs)])
      emit ctx outcome = do
        seenV <- scratchGet ctx "audit_seen"
        case seenV of
          VBool True -> pure ()
          _ -> do
            scratchSet ctx "audit_seen" (VBool True)
            modifyIORef seqR (+ 1); sq <- readIORef seqR
            opts <- readIORef options
            ctrl <- readIORef (cCtrl ctx); ac <- getp ctrl "actor"
            actor <- case ac of
              VNoval -> do a2 <- getp opts "actor"; case a2 of VNoval -> pure (VStr "anonymous"); VNull -> pure (VStr "anonymous"); _ -> pure a2
              VNull -> do a2 <- getp opts "actor"; case a2 of VNoval -> pure (VStr "anonymous"); VNull -> pure (VStr "anonymous"); _ -> pure a2
              _ -> pure ac
            now <- nowOf opts; op <- readIORef (cOp ctx)
            rv <- readIORef (cResult ctx); statusV <- case rv of VMap _ -> getp rv "status"; _ -> pure VNoval
            record <- jo [ ("seq", vint sq), ("ts", VNum now), ("actor", actor)
                         , ("entity", VStr (if opEntity op /= "" then opEntity op else "_"))
                         , ("op", VStr (if opName op /= "" then opName op else "_"))
                         , ("outcome", VStr outcome), ("status", statusV), ("correlationId", VStr (cId ctx)) ]
            a <- audit ctx; recs <- getp a "records"; appendList recs record
            mx <- optInt opts "max" 1000; trimList recs mx
            sink <- getp opts "sink"; case sink of VFunc _ -> () <$ callVfn sink record; _ -> pure ()
      hookFn name ctx = do
        a <- readIORef active
        when a $ case name of
          "PreDone" -> do ok <- resultOk ctx; emit ctx (if ok then "ok" else "error")
          "PreUnexpected" -> emit ctx "error"
          _ -> pure ()
      initFn ctx opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a; writeIORef seqR 0; _ <- audit ctx; pure ()
  pure Feature { fName = "audit", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

-- ------------------------------------------------------------------
-- clienttrack
-- ------------------------------------------------------------------

clienttrackFeature :: IO Feature
clienttrackFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  session <- newIORef ""
  requests <- newIORef (0 :: Int)
  let nameOf = do opts <- readIORef options; nm <- optStr opts "clientName" "Univec-SDK"; ver <- optStr opts "clientVersion" "0.0.1"; pure (nm ++ "/" ++ ver)
      genId kind = do
        opts <- readIORef options; v <- getp opts "idgen"
        case v of VFunc _ -> vstring <$> callVfn v (VStr kind); _ -> do { r <- randId16; let { s = take 1 kind ++ "-" ++ r }; pure (take 20 s) }
      setNC headers hname val = do e <- headerCI headers hname; when (isNoval e) (setp headers hname (VStr val))
      hookFn name ctx = do
        a <- readIORef active
        when a $ case name of
          "PostConstruct" -> do
            opts <- readIORef options; sid <- getStrD opts "sessionId" ""
            s <- if sid /= "" then pure sid else genId "session"
            writeIORef session s
            cl <- cc ctx; nm <- nameOf; tk <- jo [("session", VStr s), ("requests", VNum 0), ("clientName", VStr nm)]; trackSet cl "clienttrack" tk
          "PreRequest" -> do
            specV <- readIORef (cSpec ctx)
            case specV of
              VMap _ -> do
                s0 <- readIORef session
                s <- if s0 == "" then do opts <- readIORef options; sid <- getStrD opts "sessionId" ""; s' <- if sid /= "" then pure sid else genId "session"; writeIORef session s'; pure s' else pure s0
                opts <- readIORef options; hopt <- getp opts "headers"; let hget k d = case hopt of { VMap _ -> getStrD hopt k d; _ -> pure d }
                modifyIORef requests (+ 1); reqCount <- readIORef requests
                rid <- genId "request"; nm <- nameOf
                hdrs <- getp specV "headers"
                agentH <- hget "agent" "User-Agent"; setNC hdrs agentH nm
                clientH <- hget "client" "X-Client-Id"; setNC hdrs clientH s
                reqH <- hget "request" "X-Request-Id"; setp hdrs reqH (VStr rid)
                cl <- cc ctx
                bucket <- trackBucket cl "clienttrack" (jo [("session", VStr s), ("requests", VNum 0), ("clientName", VStr nm)])
                setp bucket "requests" (vint reqCount); setp bucket "lastRequestId" (VStr rid)
              _ -> pure ()
          _ -> pure ()
      initFn _ opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a; writeIORef requests 0
  pure Feature { fName = "clienttrack", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

-- ------------------------------------------------------------------
-- paging
-- ------------------------------------------------------------------

pagingFeature :: IO Feature
pagingFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let isList ctx = do opts <- readIORef options; ops <- optStrList opts "ops" ["list"]; op <- readIORef (cOp ctx); pure (opName op `elem` ops)
      numOf v = case v of VNoval -> VNoval; VNull -> VNoval; _ -> case reads (strip (vstring v)) :: [(Double, String)] of { [(x, "")] -> VNum x; _ -> VNoval }
      extractNext link = case (elemIndex '<' link, elemIndex '>' link) of
        (Just i, Just j) | j > i ->
          let inner = take (j - i - 1) (drop (i + 1) link)
              rest = lower (drop (j + 1) link)
          in if substrContains rest "rel" && substrContains rest "next" then Just inner else Nothing
        _ -> Nothing
      hookFn name ctx = do
        a <- readIORef active; il <- isList ctx
        when (a && il) $ case name of
          "PreRequest" -> do
            specV <- readIORef (cSpec ctx)
            case specV of
              VMap _ -> do
                qv <- getp specV "query"
                q <- case qv of VMap _ -> pure qv; _ -> do m <- emptyMap; setp specV "query" m; pure m
                opts <- readIORef options
                pageParam <- optStr opts "pageParam" "page"; limitParam <- optStr opts "limitParam" "limit"; cursorParam <- optStr opts "cursorParam" "cursor"
                ctrl <- readIORef (cCtrl ctx); pgv <- getp ctrl "paging"; let paging = case pgv of { VMap _ -> pgv; _ -> VNoval }
                -- GraphQL paginates through operation VARIABLES, not the
                -- query string. This hook runs after makeSpec, so spec.body
                -- already holds the { query, variables } envelope, and before
                -- makeFetchDef serialises it.
                point <- readIORef (cPoint ctx)
                kind <- getStrD point "kind" ""
                cur <- case paging of VMap _ -> getp paging "cursor"; _ -> pure VNoval
                if kind == "graphql" then graphqlPreRequest opts specV point paging else case cur of
                  VNoval -> do
                    pv <- getp q pageParam
                    case pv of
                      VNoval -> do
                        pgPage <- case paging of VMap _ -> getp paging "page"; _ -> pure VNoval
                        page <- case pgPage of { VNoval -> do { sp <- getp opts "startPage"; pure (case sp of { VNum n -> VNum n; _ -> VNum 1 }) }; VNull -> do { sp <- getp opts "startPage"; pure (case sp of { VNum n -> VNum n; _ -> VNum 1 }) }; p -> pure p }
                        setp q pageParam page
                      _ -> pure ()
                  VNull -> do
                    pv <- getp q pageParam
                    case pv of
                      VNoval -> do sp <- getp opts "startPage"; setp q pageParam (case sp of VNum n -> VNum n; _ -> VNum 1)
                      _ -> pure ()
                  c -> setp q cursorParam c
                when (kind /= "graphql") $ do
                  lim <- getp opts "limit"
                  case lim of VNoval -> pure (); VNull -> pure (); _ -> do lv <- getp q limitParam; case lv of VNoval -> setp q limitParam lim; _ -> pure ()
              _ -> pure ()
          "PreResult" -> do
            rv <- readIORef (cResult ctx)
            case rv of
              VMap _ -> do
                hv <- getp rv "headers"; let headers = case hv of { VMap _ -> hv; _ -> VNoval }
                headersM <- case headers of VMap _ -> pure headers; _ -> emptyMap
                body <- getp rv "body"
                xpage <- numOf <$> headerCI headersM "x-page"
                xtot <- numOf <$> headerCI headersM "x-total-count"
                xnext <- numOf <$> headerCI headersM "x-next-page"
                paging <- jo [("page", xpage), ("totalCount", xtot), ("nextPage", xnext), ("next", VNoval), ("cursor", VNoval), ("hasMore", VBool False)]
                lnk <- headerCI headersM "link"
                case lnk of VNoval -> pure (); VNull -> pure (); _ -> case extractNext (vstring lnk) of Just nx -> setp paging "next" (VStr nx); Nothing -> pure ()
                -- Relay connections carry the cursor in pageInfo, at the
                -- path the model recorded for this op. `explicitMore` is set
                -- when the server states hasMore outright, rather than
                -- leaving it to be inferred from the presence of a cursor.
                point <- readIORef (cPoint ctx)
                gqlpage <- getpathS point "graphql.page"
                relayMore <- case (gqlpage, body) of
                  (VMap _, VMap _) -> do
                    -- `connpath` locates the connection object inside the
                    -- response envelope (data.<field>); the cursor/more paths
                    -- are relative to it.
                    connpath <- getStrD gqlpage "connpath" ""
                    conn <- if null connpath then pure body else do
                      sub <- getpathS body connpath
                      pure (if isNullish sub then body else sub)
                    cursorpath <- getStrD gqlpage "cursor" ""
                    when (not (null cursorpath)) $ do
                      c <- getpathS conn cursorpath
                      when (not (isNullish c)) (setp paging "cursor" c)
                    morepath <- getStrD gqlpage "more" ""
                    if null morepath then pure False else do
                      mv <- getpathS conn morepath
                      case mv of
                        VBool mb -> do setp paging "hasMore" (VBool mb); pure True
                        _ -> pure False
                  _ -> pure False
                bodyMore <- case body of
                  VMap _ -> do
                    bn <- getp body "next"; case bn of VNoval -> pure (); VNull -> pure (); _ -> do cn <- getp paging "next"; when (isNullish cn) (setp paging "next" bn)
                    bc <- getp body "cursor"; case bc of VNoval -> pure (); VNull -> pure (); _ -> setp paging "cursor" bc
                    bnc <- getp body "nextCursor"; case bnc of VNoval -> pure (); VNull -> pure (); _ -> setp paging "cursor" bnc
                    bhm <- getp body "hasMore"; case bhm of { VBool bb -> do { setp paging "hasMore" (VBool bb); pure True }; _ -> pure False }
                  _ -> pure False
                -- Cursor presence only INFERS another page. When the server
                -- stated the answer outright — relay's `hasNextPage: false`,
                -- or a body `hasMore` — that wins: a final page normally
                -- carries both an end cursor and hasNextPage false, and
                -- inferring from the cursor there would send the caller back
                -- for a page that does not exist, forever.
                let explicitMore = relayMore || bodyMore
                hmV <- getp paging "hasMore"; nx <- getp paging "next"; cu2 <- getp paging "cursor"; np <- getp paging "nextPage"
                let hm = isTrueV hmV || not (isNullish nx) || not (isNullish cu2) || not (isNullish np)
                when (not explicitMore) (setp paging "hasMore" (VBool hm))
                setp rv "paging" paging
                cl <- cc ctx; lastM <- jo [("last", paging)]; trackSet cl "paging" lastM
              _ -> pure ()
          _ -> pure ()
      initFn _ opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a
  pure Feature { fName = "paging", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

-- Relay pagination: the cursor is the `after` variable (or whatever the model
-- named it), and the page size is `first`.
graphqlPreRequest :: Value -> Value -> Value -> Value -> IO ()
graphqlPreRequest opts specV point paging = do
  body <- getp specV "body"
  case body of
    VMap _ -> do
      vv <- getp body "variables"
      variables <- case vv of
        VMap _ -> pure vv
        _ -> do m <- emptyMap; setp body "variables" m; pure m

      afterVar <- optStr opts "afterVar" "after"
      firstVar <- optStr opts "firstVar" "first"

      -- Only bind variables the operation actually declares, or the server
      -- rejects the document.
      vl <- getpathS point "graphql.vars"
      varlist <- case vl of VList _ -> listItems vl; _ -> pure []
      declared <- mapM (\v -> getStrD v "name" "") varlist

      cur <- case paging of VMap _ -> getp paging "cursor"; _ -> pure VNoval
      when (not (isNullish cur) && afterVar `elem` declared) $
        setp variables afterVar cur

      lim <- getp opts "limit"
      existing <- getp variables firstVar
      when (not (isNullish lim) && isNullish existing && firstVar `elem` declared) $
        setp variables firstVar lim
    _ -> pure ()

elemIndex :: Eq a => a -> [a] -> Maybe Int
elemIndex x = go 0 where go _ [] = Nothing; go i (y : ys) = if x == y then Just i else go (i + 1) ys

-- ------------------------------------------------------------------
-- streaming
-- ------------------------------------------------------------------

streamingFeature :: IO Feature
streamingFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  let streamable ctx = do opts <- readIORef options; ops <- optStrList opts "ops" ["list"]; op <- readIORef (cOp ctx); pure (opName op `elem` ops)
      iterate_ result = do
        opts <- readIORef options
        chunkDelay <- optNum opts "chunkDelay" 0
        chunkSize <- optInt opts "chunkSize" 0
        resdata <- getp result "resdata"
        items0 <- case resdata of VList _ -> listItems resdata; _ -> pure []
        if chunkSize > 0
          then do
            let go [] = pure []
                go xs = do { let { (h, t) = splitAt chunkSize xs }; when (chunkDelay > 0) (sleepOf opts chunkDelay); hl <- mkList h; rest <- go t; pure (hl : rest) }
            go items0
          else mapM (\item -> do when (chunkDelay > 0) (sleepOf opts chunkDelay); pure item) items0
      hookFn name ctx = do
        a <- readIORef active; s <- streamable ctx
        when (name == "PreResult" && a && s) $ do
          rv <- readIORef (cResult ctx)
          case rv of
            VMap _ -> do
              setp rv "streaming" (VBool True)
              let streamFn = VFunc (\_ _ _ _ -> do items0 <- iterate_ rv; mkList items0)
              setp rv "stream" streamFn
              cl <- cc ctx; bucket <- trackBucket cl "streaming" (jo [("opened", VNum 0)]); bumpNum bucket "opened" 1
            _ -> pure ()
      initFn _ opts = do om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a
  pure Feature { fName = "streaming", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = hookFn }

-- ------------------------------------------------------------------
-- proxy
-- ------------------------------------------------------------------

proxyFeature :: IO Feature
proxyFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  purl <- newIORef VNoval
  noproxy <- newIORef ([] :: [String])
  let track ctx = do cl <- cc ctx; pv <- readIORef purl; bucket <- trackBucket cl "proxy" (jo [("routed", VNum 0), ("url", pv)]); bumpNum bucket "routed" 1
      bypass url = do np <- readIORef noproxy; if null np then pure False else do { let { host = urlHost url }; pure (any (\p -> p == "*" || host == p || endsWith host ("." ++ stripLeadDot p)) np) }
      route ctx url fd = do
        pv <- readIORef purl
        byp <- bypass url
        if isNullish pv || byp then pure fd
        else do
          fdC <- clone fd; out <- case fdC of VMap _ -> pure fdC; _ -> emptyMap
          setp out "proxy" pv
          proxies <- jo [("http", pv), ("https", pv)]; setp out "proxies" proxies
          opts <- readIORef options; agent <- getp opts "agent"
          case agent of { VFunc _ -> do { argsL <- ja [pv, VStr url]; made <- callVfn agent argsL; setp out "dispatcher" made; setp out "agent" made }; _ -> pure () }
          track ctx; pure out
      initFn ctx opts = do
        om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a
        when a $ do
          pv <- getp om "url"; writeIORef purl pv
          npV <- getp om "noProxy"
          npList0 <- case npV of
            VList _ -> do its <- listItems npV; pure [s | VStr s <- its]
            VStr s -> pure (filter (/= "") (map strip (splitOnChar ',' s)))
            _ -> pure []
          npListRef <- newIORef npList0
          fromEnv <- getp om "fromEnv"
          when (isTrueV fromEnv) $ do
            pcur <- readIORef purl
            when (isNullish pcur) $ do
              mv <- firstEnv ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
              case mv of Just v -> writeIORef purl (VStr v); Nothing -> pure ()
            npc <- readIORef npListRef
            when (null npc) $ do
              mv <- firstEnv ["NO_PROXY", "no_proxy"]
              case mv of Just v -> writeIORef npListRef (filter (/= "") (map strip (splitOnChar ',' v))); Nothing -> pure ()
          npFinal <- readIORef npListRef; writeIORef noproxy npFinal
          u <- cu ctx; inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\c ur f -> do f2 <- route c ur f; inner c ur f2)
  pure Feature { fName = "proxy", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

firstEnv :: [String] -> IO (Maybe String)
firstEnv [] = pure Nothing
firstEnv (k : ks) = do mv <- lookupEnv k; case mv of Just v | v /= "" -> pure (Just v); _ -> firstEnv ks

-- ------------------------------------------------------------------
-- netsim (feature)
-- ------------------------------------------------------------------

netsimFeature :: IO Feature
netsimFeature = do
  (active, fopts) <- featureBase
  options <- newIORef =<< emptyMap
  calls <- newIORef (0 :: Int)
  seedR <- newIORef (1 :: Int)
  let randD = do { s <- readIORef seedR; let { s' = (s * 1103515245 + 12345) .&. 0x7fffffff }; writeIORef seedR s'; pure (fromIntegral s' / fromIntegral (0x7fffffff :: Int)) }
      pickLatency = do
        opts <- readIORef options; lat <- getp opts "latency"
        case lat of
          VNoval -> pure 0; VNull -> pure 0
          VNum n -> pure (if n < 0 then 0 else n)
          VMap _ -> do { mn <- optInt lat "min" 0; mxv <- getp lat "max"; let { mx = case mxv of { VNum k -> truncate k; _ -> mn } }; if mx <= mn then pure (fromIntegral mn) else do { r <- randD; pure (fromIntegral (mn + truncate (r * fromIntegral (mx - mn)))) } }
          _ -> pure 0
      track ctx applied = do
        cl <- cc ctx
        bucket <- trackBucket cl "netsim" (do ap <- emptyList; jo [("calls", VNum 0), ("applied", ap)])
        bumpNum bucket "calls" 1; ap <- getp bucket "applied"; appendList ap applied
        ctrl <- readIORef (cCtrl ctx); explain <- getp ctrl "explain"; case explain of VMap _ -> setp explain "netsim" bucket; _ -> pure ()
      respond status dat extra = do
        out <- jo [("status", vint status), ("statusText", VStr "OK"), ("json", jsonThunk dat), ("body", VStr "not-used")]
        case extra of { VMap _ -> do { ks <- keysof extra; forM_ ks $ \k -> do { v <- getp extra k; setp out k v } }; _ -> pure () }
        hv <- getp out "headers"; let headers = case hv of { VMap _ -> hv; _ -> VNoval }
        headersM <- case headers of VMap _ -> pure headers; _ -> emptyMap
        lowerM <- emptyMap; hks <- keysof headersM; forM_ hks $ \k -> do v <- getp headersM k; setp lowerM (lower k) v
        setp out "headers" lowerM
        pure (out, Nothing)
      simulate ctx url fd inner = do
        opts <- readIORef options
        modifyIORef calls (+ 1); call <- readIORef calls
        applied <- emptyMap
        off <- getp opts "offline"
        if isTrueV off
          then do lat <- pickLatency; sleepOf opts lat; setp applied "offline" (VBool True); track ctx applied; e <- mkErr "netsim_offline" ("Simulated network offline (URL was: \"" ++ url ++ "\")"); pure (VNoval, Just e)
          else do
            errTimes <- optInt opts "errorTimes" 0
            if call <= errTimes
              then do lat <- pickLatency; sleepOf opts lat; setp applied "error" (VBool True); track ctx applied; e <- mkErr "netsim_conn" ("Simulated connection error (call " ++ show call ++ ")"); pure (VNoval, Just e)
              else do
                rlTimes <- optInt opts "rateLimitTimes" 0
                if call <= rlTimes
                  then do
                    lat <- pickLatency; sleepOf opts lat; setp applied "rateLimited" (VBool True); track ctx applied
                    ra <- getp opts "retryAfter"; let raN = case ra of { VNum n -> truncate n :: Int; _ -> 0 }
                    hdrs <- jo [("retry-after", VStr (show raN))]; extra <- jo [("statusText", VStr "Too Many Requests"), ("headers", hdrs)]
                    respond 429 VNoval extra
                  else do
                    failStatusV <- getp opts "failStatus"; let failStatus = case failStatusV of { VNum n -> truncate n :: Int; _ -> 503 }
                    failEvery <- optInt opts "failEvery" 0
                    failRate <- optNum opts "failRate" 0
                    failTimes <- optInt opts "failTimes" 0
                    r <- randD
                    let failByCount = call <= failTimes
                        failByEvery = failEvery > 0 && call `mod` failEvery == 0
                        failByRate = failRate > 0 && r < failRate
                    if failByCount || failByEvery || failByRate
                      then do lat <- pickLatency; sleepOf opts lat; setp applied "failStatus" (vint failStatus); track ctx applied; extra <- jo [("statusText", VStr "Simulated Failure")]; respond failStatus VNoval extra
                      else do lat <- pickLatency; setp applied "latency" (VNum lat); track ctx applied; sleepOf opts lat; inner ctx url fd
      initFn ctx opts = do
        om <- toOptsMap opts; writeIORef options om; a <- optActive opts; writeIORef active a
        sd <- getp om "seed"; writeIORef seedR (case sd of VNum n | truncate n /= (0 :: Int) -> truncate n; _ -> 1)
        when a $ do u <- cu ctx; inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\c ur f -> simulate c ur f inner)
  pure Feature { fName = "netsim", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

-- ------------------------------------------------------------------
-- test feature (in-memory mock transport + optional net simulation)
-- ------------------------------------------------------------------

testFeature :: IO Feature
testFeature = do
  (active, fopts) <- featureBase
  let respondM status dat extra = do
        out <- jo [("status", vint status), ("statusText", VStr "OK"), ("json", jsonThunk dat), ("body", VStr "not-used")]
        case extra of { Just e@(VMap _) -> do { ks <- keysof e; forM_ ks $ \k -> do { v <- getp e k; setp out k v } }; _ -> pure () }
        pure (out, Nothing)
      buildArgs fctx op args = do
        let opname = opName op
        ment <- readIORef (cEntity fctx); let entname = maybe "_" eName ment
        cfg <- readIORef (cConfig fctx)
        points <- getpathS cfg ("entity." ++ entname ++ ".op." ++ opname ++ ".points")
        point <- getelem points (VNum (-1))
        paramsPath <- getpathS point "args.params"
        reqdTrue <- jo [("reqd", VBool True)]
        reqdParams <- select paramsPath reqdTrue
        eachSpec <- ja [VStr "`$EACH`", VStr "", VStr "`$KEY.name`"]
        reqd <- transform INone reqdParams eachSpec
        qandRef <- newIORef []
        case args of
          VMap _ -> do
            ks <- keysof args
            forM_ ks $ \key -> do
              let isId = key == "id"
              sel <- select reqd (VStr key); emptySel <- isempty sel; let isReqd = not emptySel
              when (isId || isReqd) $ do
                u <- cu fctx; pfn <- readIORef (uParam u); v <- pfn fctx (VStr key)
                kaV <- case opAlias op of VMap _ -> getp (opAlias op) key; _ -> pure VNoval
                orItem1 <- jo [(key, v)]
                orList <- case kaV of { VStr s -> do { o2 <- jo [(s, v)]; ja [orItem1, o2] }; _ -> ja [orItem1] }
                orMap <- jo [("`$OR`", orList)]
                modifyIORef qandRef (++ [orMap])
          _ -> pure ()
        qand <- readIORef qandRef; qandL <- ja qand
        q <- jo [("`$AND`", qandL)]
        ctrl <- readIORef (cCtrl fctx); explain <- getp ctrl "explain"
        case explain of { VMap _ -> do { tq <- jo [("query", q)]; setp explain "test" tq }; _ -> pure () }
        pure q
      resolveMatch fctx explicit = do
        sz <- case explicit of VMap _ -> size explicit; _ -> pure 0
        let isMapNonEmpty = case explicit of { VMap _ -> sz > 0; _ -> False }
        if isMapNonEmpty then pure explicit
        else do
          mv <- readIORef (cMatch fctx); r1 <- trySrc mv
          case r1 of
            Just v -> jo [("id", v)]
            Nothing -> do dv <- readIORef (cData fctx); r2 <- trySrc dv; case r2 of Just v -> jo [("id", v)]; Nothing -> emptyMap
      trySrc src = case src of
        VMap _ -> do i <- getp src "id"; pure (case i of VNoval -> Nothing; VStr "__UNDEFINED__" -> Nothing; v -> Just v)
        _ -> pure Nothing
      makeMock entity = \fctx _url _fd -> do
        op <- readIORef (cOp fctx)
        entmapV <- getp entity (opEntity op); entmap <- case entmapV of VMap _ -> pure entmapV; _ -> emptyMap
        case opName op of
          "load" -> do
            rm <- readIORef (cReqmatch fctx); m <- resolveMatch fctx rm
            args <- buildArgs fctx op m; found <- select entmap args; ent <- getelem found (VNum 0)
            if isNullish ent then respondM 404 VNoval . Just =<< jo [("statusText", VStr "Not found")]
            else do delp ent "$KEY"; c <- clone ent; respondM 200 c Nothing
          "list" -> do
            rm <- readIORef (cReqmatch fctx)
            args <- buildArgs fctx op rm; found <- select entmap args
            if isNullish found then respondM 404 VNoval . Just =<< jo [("statusText", VStr "Not found")]
            else do { case found of { VList _ -> do { its <- listItems found; forM_ its (\i -> delp i "$KEY") }; _ -> pure () }; c <- clone found; respondM 200 c Nothing }
          "update" -> do
            rd <- readIORef (cReqdata fctx)
            um0 <- emptyMap
            case rd of VMap _ -> do { i <- getp rd "id"; case i of VNoval -> pure (); v -> setp um0 "id" v }; _ -> pure ()
            umSz <- size um0
            um <- if umSz > 0 then pure um0 else do em <- emptyMap; resolveMatch fctx em
            args <- buildArgs fctx op um; found <- select entmap args; ent0 <- getelem found (VNum 0)
            ent <- if isNullish ent0 then entFallback entmap else pure ent0
            if isNullish ent then respondM 404 VNoval . Just =<< jo [("statusText", VStr "Not found")]
            else do
              case ent of { VMap _ -> case rd of { VMap _ -> do { ks <- keysof rd; forM_ ks (\k -> do { v <- getp rd k; setp ent k v }) }; _ -> pure () }; _ -> pure () }
              delp ent "$KEY"; c <- clone ent; respondM 200 c Nothing
          "remove" -> do
            rm <- readIORef (cReqmatch fctx); m <- resolveMatch fctx rm
            args <- buildArgs fctx op m; found <- select entmap args; ent <- getelem found (VNum 0)
            case ent of VMap _ -> do { eid <- getp ent "id"; () <$ delprop entmap eid }; _ -> pure ()
            respondM 200 VNoval Nothing
          "create" -> do
            rd <- readIORef (cReqdata fctx)
            _ <- buildArgs fctx op rd
            u <- cu fctx; pfn <- readIORef (uParam u); eidV <- pfn fctx (VStr "id")
            eid <- if isNullish eidV then VStr <$> randId16 else pure eidV
            ent <- clone rd
            case ent of
              VMap _ -> do { setp ent "id" eid; case eid of { VStr s -> setp entmap s ent; _ -> pure () }; delp ent "$KEY"; c <- clone ent; respondM 200 c Nothing }
              _ -> respondM 200 ent Nothing
          _ -> respondM 404 VNoval . Just =<< jo [("statusText", VStr "Unknown operation")]
      makeNetsim net inner = do
        netcalls <- newIORef (0 :: Int)
        let pickLat = do
              lat <- getp net "latency"
              case lat of
                VNoval -> pure 0; VNull -> pure 0
                VNum n -> pure (if n < 0 then 0 else n)
                VMap _ -> do { mn <- optInt lat "min" 0; mxv <- getp lat "max"; let { mx = case mxv of { VNum k -> truncate k; _ -> mn } }; pure (if mx <= mn then fromIntegral mn else fromIntegral (mn + ((mx - mn) `div` 2))) }
                _ -> pure 0
            sleepN ms = when (ms > 0) $ do s <- getp net "sleep"; case s of VFunc _ -> () <$ callVfn s (VNum ms); _ -> realSleep ms
        pure $ \fctx url fd -> do
          modifyIORef netcalls (+ 1); call <- readIORef netcalls
          off <- getp net "offline"
          if isTrueV off then do lat <- pickLat; sleepN lat; e <- mkErr "netsim_offline" ("Simulated network offline (URL was: \"" ++ url ++ "\")"); pure (VNoval, Just e)
          else do
            errTimes <- optInt net "errorTimes" 0
            if call <= errTimes then do lat <- pickLat; sleepN lat; e <- mkErr "netsim_conn" ("Simulated connection error (call " ++ show call ++ ")"); pure (VNoval, Just e)
            else do
              failTimes <- optInt net "failTimes" 0
              if call <= failTimes then do lat <- pickLat; sleepN lat; failStatusV <- getp net "failStatus"; let { fs = case failStatusV of { VNum n -> truncate n :: Int; _ -> 503 } }; hdrs <- emptyMap; out <- jo [("status", vint fs), ("statusText", VStr "Simulated Failure"), ("body", VStr "not-used"), ("json", jsonThunk VNoval), ("headers", hdrs)]; pure (out, Nothing)
              else do lat <- pickLat; sleepN lat; inner fctx url fd
      initFn ctx opts = do
        entityV <- getp opts "entity"; entity <- case entityV of VMap _ -> pure entityV; _ -> emptyMap
        cl <- cc ctx; writeIORef (clMode cl) "test"
        let walkFn key v _parent path = do d <- size path; when (d == 2 && ismap v && not (isNullish key)) (setp v "id" key); pure v
        _ <- walk (Just walkFn) Nothing VNoval entity
        let mock = makeMock entity
        u <- cu ctx
        net <- getp opts "net"
        case net of VMap _ -> do { ns <- makeNetsim net mock; writeIORef (uFetcher u) ns }; _ -> writeIORef (uFetcher u) mock
  pure Feature { fName = "test", fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = initFn, fHook = \_ _ -> pure () }

entFallback :: Value -> IO Value
entFallback entmap = do ks <- keysof entmap; go ks
  where go [] = pure VNoval
        go (k : rest) = do v <- getp entmap k; case v of VMap _ -> pure v; _ -> go rest

-- ------------------------------------------------------------------
-- client construction + direct + prepare + test
-- ------------------------------------------------------------------

makeClientBase :: Value -> (String -> IO Feature) -> Value -> IO Client
makeClientBase config makeFeature options = do
  utility <- newUtility
  modeR <- newIORef "live"; featsR <- newIORef []; optsR <- newIORef VNoval; rootR <- newIORef Nothing; trackR <- newIORef =<< emptyMap
  let client = Client { clMode = modeR, clFeatures = featsR, clOptions = optsR, clUtility = utility, clRootctx = rootR, clTrack = trackR, clConfig = config, clMakeFeature = makeFeature }
  rootopts <- case options of VNoval -> emptyMap; _ -> pure options
  sh <- emptyMap
  rootctx <- makeContextImpl (defaultCtxSpec { csClient = Just client, csUtility = Just utility, csConfig = Just config, csOptions = Just rootopts, csShared = Just sh }) Nothing
  writeIORef rootR (Just rootctx)
  opts <- makeOptionsUtil rootctx
  writeIORef optsR opts
  ta <- getpathS opts "feature.test.active"
  when (isTrueV ta) (writeIORef modeR "test")
  writeIORef (cOptions rootctx) opts
  -- Add features in the resolved order (makeOptions records an explicit array
  -- order, else defaults to test-first). Ordering matters: the `test` feature
  -- installs the base mock transport and the transport features
  -- (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
  -- must be added before them to sit at the base of the wrapper chain.
  featureOpts <- do fmV <- toMap <$> getp opts "feature"; case fmV of VMap _ -> pure fmV; _ -> emptyMap
  orderV <- getpathS opts "__derived__.featureorder"
  order <- case orderV of VList ref -> readIORef ref; _ -> pure []
  forM_ order $ \fnameV -> case fnameV of
    VStr fname -> do
      foptsV <- toMap <$> getp featureOpts fname
      case foptsV of
        VMap _ -> do a <- getp foptsV "active"; when (isTrueV a) $ do ftr <- makeFeature fname; featureAddUtil rootctx ftr
        _ -> pure ()
    _ -> pure ()
  feats <- readIORef featsR
  forM_ feats (featureInitUtil rootctx)
  featureHookUtil rootctx "PostConstruct"
  pure client

prepare :: Client -> Value -> IO Value
prepare client fetchargs = do
  let u = clUtility client
  fa <- case fetchargs of VNoval -> emptyMap; _ -> pure fetchargs
  ctrlV <- toMap <$> getp fa "ctrl"
  ctrl <- case ctrlV of VMap _ -> pure ctrlV; _ -> emptyMap
  root <- readIORef (clRootctx client)
  ctx <- makeContextImpl (defaultCtxSpec { csOpname = Just "prepare", csCtrl = Just ctrl }) root
  options <- readIORef (clOptions client)
  path <- getStrD fa "path" ""
  method <- getStrD fa "method" "GET"
  paramsV <- toMap <$> getp fa "params"; params <- case paramsV of VMap _ -> pure paramsV; _ -> emptyMap
  queryV <- toMap <$> getp fa "query"; query <- case queryV of VMap _ -> pure queryV; _ -> emptyMap
  headers <- prepareHeadersUtil ctx
  base <- getStrD options "base" ""; prefix <- getStrD options "prefix" ""; suffix <- getStrD options "suffix" ""
  body <- getp fa "body"
  specm <- jo [("base", VStr base), ("prefix", VStr prefix), ("suffix", VStr suffix), ("path", VStr path), ("method", VStr method), ("params", params), ("query", query), ("headers", headers), ("body", body), ("step", VStr "start")]
  sp <- newSpec specm
  writeIORef (cSpec ctx) sp
  uh <- getp fa "headers"
  case uh of VMap _ -> do { spH <- getp sp "headers"; ks <- keysof uh; forM_ ks (\k -> do { v <- getp uh k; setp spH k v }) }; _ -> pure ()
  (_, merr) <- prepareAuthUtil ctx
  case merr of Just e -> throwIO (SdkException e); Nothing -> pure ()
  (fd, merr2) <- makeFetchDefUtil ctx
  case merr2 of Just e -> throwIO (SdkException e); Nothing -> pure fd

-- Is this raw-access op permitted by the SDK's allow.op option?
opAllowed :: Client -> String -> IO Bool
opAllowed client op = do
  opts <- readIORef (clOptions client)
  allow <- getpathS opts "allow.op"
  pure (case allow of VStr s -> substrContains s op; _ -> False)

opDenied :: Client -> String -> IO Value
opDenied client op = do
  opts <- readIORef (clOptions client)
  allow <- getpathS opts "allow.op"
  let a = case allow of VStr s -> s; _ -> ""
  jo [ ("ok", VBool False)
     , ("err", VStr ("UnivecSDK: " ++ op ++ ": operation not allowed by"
                     ++ " SDK option allow.op value: \"" ++ a ++ "\"")) ]

-- Raw endpoint access is operator-controllable, like every entity op.
-- Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
-- either one reaches the same endpoint.
direct :: Client -> Value -> IO Value
direct client fetchargs = do
  allowed <- opAllowed client "direct"
  if not allowed then opDenied client "direct" else rawRequest client fetchargs

-- Raw GraphQL access: the pressure valve that makes the generated surface's
-- deliberate omissions (per-call selection sets, typed filter builders,
-- batching, subscriptions) livable — the whole schema stays reachable.
--
-- Thin wrapper over the same prepare/fetch path direct uses, with the one
-- thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200 as
-- a top-level `errors` array, so status alone would report a failed query as
-- ok.
--
-- NOTE: like direct, this bypasses the feature pipeline — no retry, ratelimit
-- or paging features apply.
graphql :: Client -> String -> Value -> Value -> IO Value
graphql client query variables ctrl = do
  allowed <- opAllowed client "graphql"
  if not allowed then opDenied client "graphql" else do
    vars <- case variables of VMap _ -> pure variables; _ -> emptyMap
    ctl <- case ctrl of VMap _ -> pure ctrl; _ -> emptyMap
    headers <- jo [("content-type", VStr "application/json")]
    body <- jo [("query", VStr query), ("variables", vars)]
    fa <- jo [ ("method", VStr "POST"), ("headers", headers)
             , ("body", body), ("ctrl", ctl) ]
    res <- rawRequest client fa

    -- Errors are read BEFORE any status check: a GraphQL parse or validation
    -- failure comes back as HTTP 400 carrying the standard { errors: [...] }
    -- body, and the raw path represents a non-2xx as ok:False with no err —
    -- so returning early on status would discard the server's own
    -- diagnostics, which are the only useful part of that response.
    ev <- getpathS res "data.errors"
    errors <- case ev of VList _ -> listItems ev; _ -> pure []
    case errors of
      [] -> pure res
      (firsterr : _) -> do
        m0 <- getStrD firsterr "message" ""
        let msg = if null m0 then "graphql error" else m0
        setp res "ok" (VBool False)
        setp res "err" (VStr ("UnivecSDK: graphql: " ++ msg))
        setp res "graphql" ev
        pure res

-- Ungated request path shared by direct and graphql, each of which checks its
-- own allow.op token first. Separate, rather than a flag on fetchargs: a
-- caller-supplied marker would let anyone opt straight back out of the gate
-- by passing it.
rawRequest :: Client -> Value -> IO Value
rawRequest client fetchargs = do
  let u = clUtility client
  fa <- case fetchargs of VNoval -> emptyMap; _ -> pure fetchargs
  res <- try (prepare client fa) :: IO (Either SdkException Value)
  case res of
    Left (SdkException e) -> do ev <- errToValue e; jo [("ok", VBool False), ("err", ev)]
    Right fetchdef -> do
      ctrlV <- toMap <$> getp fa "ctrl"; ctrl <- case ctrlV of VMap _ -> pure ctrlV; _ -> emptyMap
      root <- readIORef (clRootctx client)
      ctx <- makeContextImpl (defaultCtxSpec { csOpname = Just "direct", csCtrl = Just ctrl }) root
      url <- getStrD fetchdef "url" ""
      fetcher <- readIORef (uFetcher u)
      (fetched, ferr) <- fetcher ctx url fetchdef
      case ferr of
        Just fe -> do ev <- errToValue fe; jo [("ok", VBool False), ("err", ev)]
        Nothing ->
          if isNoval fetched || isNullV fetched
            then do e <- mkErr "direct_no_response" "response: undefined"; ev <- errToValue e; jo [("ok", VBool False), ("err", ev)]
            else case fetched of
              VMap _ -> do
                st <- getp fetched "status"; let status = toInt st
                headersV <- getp fetched "headers"; headers <- case headersV of VMap _ -> pure headersV; _ -> emptyMap
                clv <- getp headers "content-length"; let cl = case clv of { VStr s -> s; VNum n -> show (truncate n :: Int); _ -> "" }
                let noBody = status == 204 || status == 304 || cl == "0"
                jsonData <- if noBody then pure VNoval else do jf <- getp fetched "json"; case jf of VFunc _ -> callJson jf; _ -> pure VNoval
                jo [("ok", VBool (status >= 200 && status < 300)), ("status", vint status), ("headers", headers), ("data", jsonData)]
              _ -> do e <- mkErr "direct_invalid" "invalid response type"; ev <- errToValue e; jo [("ok", VBool False), ("err", ev)]

sdkTest :: Value -> (String -> IO Feature) -> Value -> Value -> IO Client
sdkTest config makeFeature testopts sdkopts = do
  so0 <- case sdkopts of VNoval -> emptyMap; _ -> pure sdkopts
  soC <- clone so0; sdkopts' <- case soC of VMap _ -> pure soC; _ -> emptyMap
  to0 <- case testopts of VNoval -> emptyMap; _ -> pure testopts
  toC <- clone to0; testopts' <- case toC of VMap _ -> pure toC; _ -> emptyMap
  setp testopts' "active" (VBool True)
  p <- ja [VStr "feature", VStr "test"]
  _ <- setpath sdkopts' p testopts'
  sdk <- makeClientBase config makeFeature sdkopts'
  writeIORef (clMode sdk) "test"
  pure sdk

-- ------------------------------------------------------------------
-- generic entity (config-driven)
-- ------------------------------------------------------------------

runOpPipeline :: Context -> IO () -> IO Value
runOpPipeline ctx postDone = do
  let fh n = featureHookUtil ctx n
      setOut k v = do out <- readIORef (cOut ctx); setp out k v
  fh "PrePoint"
  (point, e1) <- makePointUtil ctx
  case e1 of
    Just e -> makeErrorUtil ctx (Just e)
    Nothing -> do
      setOut "point" point
      fh "PreSpec"
      (spec, e2) <- makeSpecUtil ctx
      case e2 of
        Just e -> makeErrorUtil ctx (Just e)
        Nothing -> do
          setOut "spec" spec
          fh "PreRequest"
          (resp, e3) <- makeRequestUtil ctx
          case e3 of
            Just e -> makeErrorUtil ctx (Just e)
            Nothing -> do
              setOut "request" resp
              fh "PreResponse"
              (resp2, e4) <- makeResponseUtil ctx
              case e4 of
                Just e -> makeErrorUtil ctx (Just e)
                Nothing -> do
                  setOut "response" resp2
                  fh "PreResult"
                  (result, e5) <- makeResultUtil ctx
                  case e5 of
                    Just e -> makeErrorUtil ctx (Just e)
                    Nothing -> do
                      setOut "result" result
                      fh "PreDone"
                      postDone
                      doneUtil ctx

-- Truncate a materialised stream when the signal fn returns true (checked
-- before each element, mirroring an async iterator's per-yield cancellation).
streamTakeUntil :: Value -> [Value] -> IO [Value]
streamTakeUntil _ [] = pure []
streamTakeUntil sig (x : xs) = do
  r <- callVfn sig VNoval
  if isTrueV r then pure [] else do rest <- streamTakeUntil sig xs; pure (x : rest)

makeEntity :: Client -> String -> Value -> IO Entity
makeEntity client name entopts = do
  entopts' <- case entopts of VMap _ -> pure entopts; _ -> emptyMap
  a <- getBool entopts' "active"
  case a of Just False -> pure (); _ -> setp entopts' "active" (VBool True)
  utility <- copyUtility (clUtility client)
  dataR <- newIORef =<< emptyMap
  matchR <- newIORef =<< emptyMap
  deletedR <- newIORef False
  entctxR <- newIORef Nothing
  let entCtx = do m <- readIORef entctxR; case m of Just c -> pure c; Nothing -> error "entity context not initialised"
      setDataFrom rv = do
        resdata <- getp rv "resdata"
        when (not (isNoval resdata) && not (isNullV resdata)) $ do { c <- clone resdata; m <- case toMap c of { VMap _ -> pure c; _ -> emptyMap }; writeIORef dataR m }
      setMatchFrom rv = do resmatch <- getp rv "resmatch"; case resmatch of VMap _ -> writeIORef matchR resmatch; _ -> pure ()
      mkOp opname inputKind reqval ctrl postDone = do
        ec <- entCtx
        mv <- readIORef matchR; dv <- readIORef dataR
        mC <- clone mv; dC <- clone dv
        ctrlM <- case toMap ctrl of VMap _ -> pure ctrl; _ -> emptyMap
        let base = defaultCtxSpec { csOpname = Just opname, csCtrl = Just ctrlM, csMatch = Just mC, csData = Just dC }
            cspec = if inputKind == "data" then base { csReqdata = Just reqval } else base { csReqmatch = Just reqval }
        ctx <- makeContextImpl cspec (Just ec)
        runOpPipeline ctx (postDone ctx)
      postLoad ctx = do rv <- readIORef (cResult ctx); case rv of VMap _ -> do { setMatchFrom rv; setDataFrom rv }; _ -> pure ()
      postList ctx = do rv <- readIORef (cResult ctx); case rv of VMap _ -> setMatchFrom rv; _ -> pure ()
      postCreate ctx = do rv <- readIORef (cResult ctx); case rv of VMap _ -> setDataFrom rv; _ -> pure ()
      postUpdate = postLoad
      postRemove = postLoad
  let ent = Entity
        { eName = name, eClient = client, eUtility = utility, eEntopts = entopts'
        , eData = dataR, eMatch = matchR, eEntctx = entctxR
        , eMake = do o <- clone entopts'; makeEntity client name o
        , eDataSet = \d -> writeIORef dataR d
        , eDataGet = readIORef dataR
        -- Ops resolve to the ENTITY (see SdkTypes). mkOp still runs the whole
        -- pipeline and throws SdkException on failure; with throwing disabled
        -- it returns the error payload, which an IO Entity cannot carry, so
        -- that path resolves to the entity too and the caller reads ctrl.err
        -- — the mechanism the no-throw mode documents anyway.
        , eLoad = \rm ctrl -> mkOp "load" "match" rm ctrl postLoad >> pure ent
        , eList = \rm ctrl -> do
            out <- mkOp "list" "match" rm ctrl postList
            -- `list` resolves to one ENTITY per record. makeResult cannot
            -- build them — it works in Value — so this does.
            case out of
              VList _ -> do
                items <- listItems out
                mapM (\entry -> do
                        e <- eMake ent
                        case entry of VMap _ -> eDataSet e entry; _ -> pure ()
                        pure e) items
              _ -> pure []
        , eCreate = \rd ctrl -> mkOp "create" "data" rd ctrl postCreate >> pure ent
        , eUpdate = \rd ctrl -> mkOp "update" "data" rd ctrl postUpdate >> pure ent
        , eRemove = \rm ctrl -> do
            _ <- mkOp "remove" "match" rm ctrl postRemove
            -- A removed entity keeps its data but is no longer a live record.
            writeIORef deletedR True
            pure ent
        , eDeleted = deletedR
        , eMarkDeleted = writeIORef deletedR True
        -- Streaming operation. Runs `action` through the full pipeline and
        -- returns a lazy list of result items, so the streaming feature's
        -- incremental output is reachable (a normal op call materialises the
        -- whole result). When the streaming feature is active the result
        -- carries a stream closure and this yields from it (honouring
        -- chunkSize); otherwise it falls back to the materialised items, so
        -- stream always yields. callopts: ctrl (per-call pipeline control),
        -- body (an enumerable/list payload attached to the request for
        -- outbound streaming), signal (a 0-arity fn -> Bool; stop when true).
        , eStream = \action args callopts -> do
            ec <- entCtx
            coV <- case toMap callopts of VMap _ -> pure callopts; _ -> emptyMap
            ctrlV <- getp coV "ctrl"
            ctrl <- case toMap ctrlV of VMap _ -> pure ctrlV; _ -> emptyMap
            setp ctrl "stream" coV
            mv <- readIORef matchR; dv <- readIORef dataR
            mC <- clone mv; dC <- clone dv
            reqmatch <- case toMap args of VMap _ -> pure args; _ -> emptyMap
            let cspec = defaultCtxSpec { csOpname = Just action, csCtrl = Just ctrl, csMatch = Just mC, csData = Just dC, csReqmatch = Just reqmatch }
            ctx <- makeContextImpl cspec (Just ec)
            body <- getp coV "body"
            when (not (isNoval body) && not (isNullV body)) $ do
              rdV <- readIORef (cReqdata ctx)
              rd <- case rdV of VMap _ -> pure rdV; _ -> emptyMap
              setp rd "body$" body
              writeIORef (cReqdata ctx) rd
            _ <- runOpPipeline ctx (pure ())
            rv <- readIORef (cResult ctx)
            raw <- case rv of
              VMap _ -> do
                sf <- getp rv "stream"
                case sf of
                  VFunc _ -> do r <- callVfn sf VNoval; case r of VList _ -> listItems r; _ -> pure []
                  _ -> do resdata <- getp rv "resdata"; case resdata of VList _ -> listItems resdata; VNoval -> pure []; v -> pure [v]
              _ -> pure []
            sig <- getp coV "signal"
            case sig of
              VFunc _ -> streamTakeUntil sig raw
              _ -> pure raw
        }
  root <- readIORef (clRootctx client)
  entctx <- makeContextImpl (defaultCtxSpec { csEntity = Just ent, csEntopts = Just entopts' }) root
  featureHookUtil entctx "PostConstructEntity"
  writeIORef entctxR (Just entctx)
  pure ent

-- public entity data/match accessors (fire hooks)
entityData :: Entity -> Maybe Value -> IO Value
entityData ent margs = do
  case margs of
    Just arg | not (isNoval arg) && not (isNullV arg) -> do
      c <- clone arg; m <- case toMap c of { VMap _ -> pure c; _ -> emptyMap }
      writeIORef (eData ent) m
      ec <- entCtxOf ent; featureHookUtil ec "SetData"
    _ -> pure ()
  ec <- entCtxOf ent; featureHookUtil ec "GetData"
  d <- readIORef (eData ent); clone d

entityMatch :: Entity -> Maybe Value -> IO Value
entityMatch ent margs = do
  case margs of
    Just arg | not (isNoval arg) && not (isNullV arg) -> do
      c <- clone arg; m <- case toMap c of { VMap _ -> pure c; _ -> emptyMap }
      writeIORef (eMatch ent) m
      ec <- entCtxOf ent; featureHookUtil ec "SetMatch"
    _ -> pure ()
  ec <- entCtxOf ent; featureHookUtil ec "GetMatch"
  m <- readIORef (eMatch ent); clone m

entCtxOf :: Entity -> IO Context
entCtxOf ent = do m <- readIORef (eEntctx ent); case m of Just c -> pure c; Nothing -> error "entity context not initialised"
