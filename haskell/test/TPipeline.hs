-- Direct unit tests for the operation-pipeline utilities (mirrors the dynamic
-- donors' test_pipeline). Drives the error/edge branches a happy-path op never
-- reaches. API-agnostic: everything is reached through the client utility.

module TPipeline (tests) where

import Data.IORef
import Data.Maybe (isNothing)

import VoxgigStruct (Value (..), emptyMap, emptyList, mkList, size, ismap, isNoval, vint)
import SdkTypes
import SdkHelpers
import SdkRuntime
import qualified SdkFeatures as F
import qualified SdkClient as C
import Testutil

client :: IO Client
client = C.testSdk0

mkCtx :: Client -> String -> IO Context
mkCtx cl opname = do
  root <- readIORef (clRootctx cl)
  makeContextImpl (defaultCtxSpec { csOpname = Just opname, csClient = Just cl, csUtility = Just (clUtility cl) }) root

mkCtxCtrl :: Client -> String -> Value -> IO Context
mkCtxCtrl cl opname ctrl = do
  root <- readIORef (clRootctx cl)
  makeContextImpl (defaultCtxSpec { csOpname = Just opname, csClient = Just cl, csUtility = Just (clUtility cl), csCtrl = Just ctrl }) root

fullSpec :: IO Value
fullSpec = do
  pm <- emptyMap; qm <- emptyMap; hm <- emptyMap
  newSpec =<< jo [("base", VStr "http://h"), ("prefix", VStr ""), ("suffix", VStr ""), ("path", VStr "a"), ("method", VStr "GET"), ("params", pm), ("query", qm), ("headers", hm), ("step", VStr "s")]

respMap :: Int -> Value -> [(String, Value)] -> IO Value
respMap status dat headers = do
  hm <- emptyMap
  mapM_ (\(k, v) -> setp hm (lower k) v) headers
  newResponse =<< jo [("status", vint status), ("statusText", VStr (if status < 400 then "OK" else "ERR")), ("headers", hm), ("json", jsonThunk dat), ("body", VStr "body")]

namedFeature :: String -> Value -> IO Feature
namedFeature nm opts = do
  active <- newIORef True; fopts <- newIORef opts
  pure Feature { fName = nm, fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = \_ _ -> pure (), fHook = \_ _ -> pure () }

errCodeIs :: Value -> String -> IO Bool
errCodeIs e code = do c <- errCode e; pure (c == code)

tests :: Counters -> IO ()
tests c = do
  -- feature order (PR review #2): makeOptions resolves the feature add-order
  -- into __derived__.featureorder. A map defaults test-first (so the test mock
  -- is the base transport), an explicit array preserves the developer order,
  -- and a map without test is deterministic (names sorted).
  let orderNames opts = do
        fo <- getpathS opts "__derived__.featureorder"
        case fo of
          VList ref -> do { xs <- readIORef ref; pure [s | VStr s <- xs] }
          _ -> pure []
      resolveOrder feature = do
        cl <- client
        ctx <- mkCtx cl "load"
        o <- jo [("feature", feature)]; writeIORef (cOptions ctx) o
        cfgo <- emptyMap; cf <- jo [("options", cfgo)]; writeIORef (cConfig ctx) cf
        makeOptionsUtil ctx

  runTest c "feature_order.map_test_first" $ do
    m <- jo [("active", VBool True)]; t <- jo [("active", VBool True)]
    feat <- jo [("metrics", m), ("test", t)]
    o <- resolveOrder feat
    order <- orderNames o
    pure (order == ["test", "metrics"])

  runTest c "feature_order.array_preserves_order" $ do
    e1 <- jo [("name", VStr "metrics"), ("active", VBool True)]
    e2 <- jo [("name", VStr "test"), ("active", VBool True)]
    feat <- ja [e1, e2]
    o <- resolveOrder feat
    order <- orderNames o
    ma <- getpathS o "feature.metrics.active"
    ta <- getpathS o "feature.test.active"
    pure (order == ["metrics", "test"] && isTrueV ma && isTrueV ta)

  runTest c "feature_order.map_no_test_deterministic" $ do
    r <- jo [("active", VBool True)]; ca <- jo [("active", VBool True)]
    feat <- jo [("retry", r), ("cache", ca)]
    o <- resolveOrder feat
    order <- orderNames o
    pure (order == ["cache", "retry"])

  runTest c "make_point.rejects_disallowed_op" $ do
    cl <- client; ctx <- mkCtx cl "nope"
    ao <- jo [("op", VStr "load")]; o <- jo [("allow", ao)]; writeIORef (cOptions ctx) o
    (_, merr) <- makePointUtil ctx
    case merr of Just e -> errCodeIs e "point_op_allow"; Nothing -> pure False

  runTest c "make_point.rejects_no_endpoints" $ do
    cl <- client; ctx <- mkCtx cl "load"
    (_, merr) <- makePointUtil ctx
    case merr of Just e -> errCodeIs e "point_no_points"; Nothing -> pure False

  runTest c "make_point.single_point" $ do
    cl <- client; ctx <- mkCtx cl "load"
    parts <- ja [VStr "a"]
    point <- jo [("method", VStr "GET"), ("parts", parts)]
    pts <- ja [point]
    op <- newOperation =<< jo [("name", VStr "load"), ("points", pts)]
    writeIORef (cOp ctx) op
    (out, merr) <- makePointUtil ctx
    m <- getp out "method"
    pt <- readIORef (cPoint ctx)
    pure (isNothing merr && vstring m == "GET" && ismap pt)

  runTest c "make_point.short_circuits_preset" $ do
    cl <- client; ctx <- mkCtx cl "load"
    preset <- jo [("method", VStr "GET")]
    out <- readIORef (cOut ctx); setp out "point" preset
    (o, merr) <- makePointUtil ctx
    m <- getp o "method"
    pure (isNothing merr && vstring m == "GET")

  runTest c "make_point.surfaces_feature_error" $ do
    cl <- client; ctx <- mkCtx cl "load"
    denied <- mkErr "rbac_denied" "no permission"
    out <- readIORef (cOut ctx); setp out "point" denied
    (_, merr) <- makePointUtil ctx
    case merr of Just e -> errCodeIs e "rbac_denied"; Nothing -> pure False

  runTest c "make_spec.short_circuits_preset" $ do
    cl <- client; ctx <- mkCtx cl "load"
    preset <- newSpec =<< jo [("method", VStr "GET")]
    out <- readIORef (cOut ctx); setp out "spec" preset
    (o, merr) <- makeSpecUtil ctx
    m <- getp o "method"
    pure (isNothing merr && vstring m == "GET")

  runTest c "make_spec.surfaces_feature_error" $ do
    cl <- client; ctx <- mkCtx cl "load"
    boom <- mkErr "boom" "boom"
    out <- readIORef (cOut ctx); setp out "spec" boom
    (_, merr) <- makeSpecUtil ctx
    case merr of Just e -> errCodeIs e "boom"; Nothing -> pure False

  runTest c "make_response.guard_no_spec" $ do
    cl <- client; ctx <- mkCtx cl "load"
    writeIORef (cSpec ctx) VNoval
    r <- respMap 200 VNoval []; writeIORef (cResponse ctx) r
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    (_, merr) <- makeResponseUtil ctx
    case merr of Just e -> errCodeIs e "response_no_spec"; Nothing -> pure False

  runTest c "make_response.4xx_sets_err_and_headers" $ do
    cl <- client; ctx <- mkCtx cl "load"
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    r <- respMap 404 VNoval [("x-a", VStr "1")]; writeIORef (cResponse ctx) r
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    _ <- makeResponseUtil ctx
    rv <- readIORef (cResult ctx)
    errv <- getp rv "err"; isE <- isErr errv
    st <- getp rv "status"; ha <- getp rv "headers" >>= \h -> getp h "x-a"
    ok <- getp rv "ok"
    pure (isE && toInt st == 404 && vstring ha == "1" && not (isTrueV ok))

  runTest c "make_response.2xx_parses_body" $ do
    cl <- client; ctx <- mkCtx cl "load"
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    d <- jo [("v", VNum 1)]
    r <- respMap 200 d []; writeIORef (cResponse ctx) r
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    _ <- makeResponseUtil ctx
    rv <- readIORef (cResult ctx)
    ok <- getp rv "ok"; bv <- getp rv "body" >>= \b -> getp b "v"
    pure (isTrueV ok && (case bv of VNum n -> n == 1; _ -> False))

  runTest c "make_response.records_explain" $ do
    cl <- client; ex <- emptyMap; ctrl <- jo [("explain", ex)]
    ctx <- mkCtxCtrl cl "load" ctrl
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    d <- jo [("v", VNum 2)]; r <- respMap 200 d []; writeIORef (cResponse ctx) r
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    _ <- makeResponseUtil ctx
    ctrlV <- readIORef (cCtrl ctx); exv <- getp ctrlV "explain"; resv <- getp exv "result"
    pure (ismap resv)

  runTest c "make_result.guard_no_result" $ do
    cl <- client; ctx <- mkCtx cl "load"
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    writeIORef (cResult ctx) VNoval
    (_, merr) <- makeResultUtil ctx
    case merr of Just e -> errCodeIs e "result_no_result"; Nothing -> pure False

  runTest c "make_result.list_wraps_resdata" $ do
    cl <- client; ctx <- mkCtx cl "list"
    ent <- F.makeEntity cl "planet" VNoval; writeIORef (cEntity ctx) (Just ent)
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    a1 <- jo [("a", VNum 1)]; a2 <- jo [("a", VNum 2)]; rd <- ja [a1, a2]
    res <- newResult =<< jo [("resdata", rd)]; writeIORef (cResult ctx) res
    (ro, merr) <- makeResultUtil ctx
    n <- getp ro "resdata" >>= size
    pure (isNothing merr && n == 2)

  runTest c "make_request.guard_no_spec" $ do
    cl <- client; ctx <- mkCtx cl "load"
    writeIORef (cSpec ctx) VNoval
    (_, merr) <- makeRequestUtil ctx
    case merr of Just e -> errCodeIs e "request_no_spec"; Nothing -> pure False

  runTest c "make_request.transport_error_on_response" $ do
    cl <- client; ctx <- mkCtx cl "load"
    u <- copyUtility (clUtility cl)
    boom <- mkErr "boom" "boom"
    writeIORef (uFetcher u) (\_ _ _ -> pure (VNoval, Just boom))
    writeIORef (cUtility ctx) (Just u)
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    (ro, _) <- makeRequestUtil ctx
    errv <- getp ro "err"; errCodeIs errv "boom"

  runTest c "make_request.null_transport" $ do
    cl <- client; ctx <- mkCtx cl "load"
    u <- copyUtility (clUtility cl)
    writeIORef (uFetcher u) (\_ _ _ -> pure (VNoval, Nothing))
    writeIORef (cUtility ctx) (Just u)
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    (ro, _) <- makeRequestUtil ctx
    errv <- getp ro "err"; errCodeIs errv "request_no_response"

  runTest c "make_fetch_def.guard_no_spec" $ do
    cl <- client; ctx <- mkCtx cl "load"
    writeIORef (cSpec ctx) VNoval
    (_, merr) <- makeFetchDefUtil ctx
    case merr of Just e -> errCodeIs e "fetchdef_no_spec"; Nothing -> pure False

  runTest c "make_fetch_def.serialises_body" $ do
    cl <- client; ctx <- mkCtx cl "load"
    writeIORef (cResult ctx) VNoval
    sp <- fullSpec; setp sp "method" (VStr "POST"); b <- jo [("x", VNum 1)]; setp sp "body" b
    writeIORef (cSpec ctx) sp
    (fd, merr) <- makeFetchDefUtil ctx
    bs <- getp fd "body"
    rv <- readIORef (cResult ctx)
    pure (isNothing merr && (case bs of VStr s -> not (null s); _ -> False) && ismap rv)

  runTest c "done.returns_resdata_on_success" $ do
    cl <- client; ctx <- mkCtx cl "load"
    res <- newResult =<< jo [("ok", VBool True), ("resdata", VNum 42)]; writeIORef (cResult ctx) res
    r <- doneUtil ctx
    pure (case r of VNum n -> n == 42; _ -> False)

  runTest c "make_error.returns_resdata_when_throw_disabled" $ do
    cl <- client; ctrl <- jo [("throw_err", VBool False)]
    ctx <- mkCtxCtrl cl "load" ctrl
    res <- newResult =<< jo [("ok", VBool False), ("resdata", VStr "fallback")]; writeIORef (cResult ctx) res
    r <- makeErrorUtil ctx Nothing
    pure (vstring r == "fallback")

  runTest c "make_error.records_explain" $ do
    cl <- client; ex <- emptyMap; ctrl <- jo [("throw_err", VBool False), ("explain", ex)]
    ctx <- mkCtxCtrl cl "load" ctrl
    res <- newResult =<< jo [("ok", VBool False)]; writeIORef (cResult ctx) res
    _ <- makeErrorUtil ctx Nothing
    ctrlV <- readIORef (cCtrl ctx); exv <- getp ctrlV "explain"; errv <- getp exv "err"
    pure (ismap errv)

  runTest c "feature_add.appends_in_order" $ do
    cl <- client; ctx <- mkCtx cl "load"
    start <- readIORef (clFeatures cl) >>= \fs -> pure (map fName fs)
    a <- namedFeature "aaa" VNoval; z <- namedFeature "zzz" VNoval
    featureAddUtil ctx a; featureAddUtil ctx z
    names <- readIORef (clFeatures cl) >>= \fs -> pure (map fName fs)
    pure (names == start ++ ["aaa", "zzz"])

  runTest c "feature_add.ordering" $ do
    cl <- client; ctx <- mkCtx cl "load"
    writeIORef (clFeatures cl) []
    let names = readIORef (clFeatures cl) >>= \fs -> pure (map fName fs)
    fa <- namedFeature "a" VNoval; fb <- namedFeature "b" VNoval
    featureAddUtil ctx fa; featureAddUtil ctx fb
    n1 <- names
    ob <- jo [("__before__", VStr "b")]; z1 <- namedFeature "z1" ob; featureAddUtil ctx z1
    n2 <- names
    oa <- jo [("__after__", VStr "a")]; z2 <- namedFeature "z2" oa; featureAddUtil ctx z2
    n3 <- names
    orp <- jo [("__replace__", VStr "z1")]; z3 <- namedFeature "z3" orp; featureAddUtil ctx z3
    n4 <- names
    om <- jo [("__before__", VStr "missing")]; z4 <- namedFeature "z4" om; featureAddUtil ctx z4
    n5 <- names
    pure (n1 == ["a", "b"] && n2 == ["a", "z1", "b"] && n3 == ["a", "z2", "z1", "b"] && n4 == ["a", "z2", "z3", "b"] && n5 == ["a", "z2", "z3", "b", "z4"])

  runTest c "feature.transport_wrapping_order" $ do
    cl <- client; ctx <- readIORef (clRootctx cl) >>= \(Just r) -> pure r
    let u = clUtility cl
    order <- newIORef []
    writeIORef (uFetcher u) (\_ _ _ -> do modifyIORef order (++ ["server"]); r <- jo [("status", VNum 200), ("statusText", VStr "OK")]; pure (r, Nothing))
    let wrap tag = do inner <- readIORef (uFetcher u); writeIORef (uFetcher u) (\cc url fd -> do modifyIORef order (++ [tag]); inner cc url fd)
    wrap "first"; wrap "second"
    fetcher <- readIORef (uFetcher u)
    hm <- emptyMap; fd <- jo [("method", VStr "GET"), ("headers", hm)]
    _ <- fetcher ctx "http://h/a" fd
    o <- readIORef order
    pure (o == ["second", "first", "server"])

  runTest c "prepare_auth.apikey_prefix_space_joined" $ do
    cl <- client; ctx <- mkCtx cl "load"
    ap <- jo [("prefix", VStr "Bearer")]; o <- jo [("apikey", VStr "K"), ("auth", ap)]; writeIORef (clOptions cl) o
    hm <- emptyMap; sp <- newSpec =<< jo [("headers", hm)]; writeIORef (cSpec ctx) sp
    _ <- prepareAuthUtil ctx
    spv <- readIORef (cSpec ctx); h <- getp spv "headers"; av <- getp h "authorization"
    pure (vstring av == "Bearer K")

  runTest c "prepare_auth.empty_apikey_drops_header" $ do
    cl <- client; ctx <- mkCtx cl "load"
    ap <- jo [("prefix", VStr "Bearer")]; o <- jo [("apikey", VStr ""), ("auth", ap)]; writeIORef (clOptions cl) o
    stale <- jo [("authorization", VStr "stale")]; sp <- newSpec =<< jo [("headers", stale)]; writeIORef (cSpec ctx) sp
    _ <- prepareAuthUtil ctx
    spv <- readIORef (cSpec ctx); h <- getp spv "headers"; av <- getp h "authorization"
    pure (isNoval av)

  runTest c "result_headers.no_headers_empty_map" $ do
    cl <- client; ctx <- mkCtx cl "load"
    r <- newResponse =<< jo [("status", VNum 200)]; writeIORef (cResponse ctx) r
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    resultHeadersUtil ctx
    rv <- readIORef (cResult ctx); h <- getp rv "headers"; n <- size h
    pure (n == 0)

  runTest c "result_body.skips_absent_body" $ do
    cl <- client; ctx <- mkCtx cl "load"
    d <- jo [("a", VNum 1)]
    r <- newResponse =<< jo [("status", VNum 200), ("json", jsonThunk d)]; writeIORef (cResponse ctx) r
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    resultBodyUtil ctx
    rv <- readIORef (cResult ctx); b <- getp rv "body"
    pure (isNoval b)
