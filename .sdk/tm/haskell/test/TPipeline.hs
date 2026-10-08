-- Direct unit tests for the operation-pipeline utilities (mirrors the dynamic
-- donors' test_pipeline). Drives the error/edge branches a happy-path op never
-- reaches. API-agnostic: everything is reached through the client utility.

module TPipeline (tests) where

import Control.Exception (try)
import Data.IORef
import Data.List (isInfixOf, isSuffixOf)
import Data.Maybe (isNothing)

import VoxgigStruct (Value (..), InjArg (INone), emptyMap, emptyList, mkList, size, ismap, isNoval, vint, listItems, transform, jsonEncode)
import SdkTypes
import SdkHelpers
import SdkRuntime
import qualified SdkFeatures as F
import qualified SdkClient as C
import SdkConfig (makeConfig, makeFeature)
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

prepareAs :: Client -> String -> IO (Either SdkException Value)
prepareAs cl m = do
  fa <- jo [("path", VStr "/a"), ("method", VStr m)]
  try (F.prepare cl fa)

-- Whether the client prepares a POST and refuses a HEAD with spec_method_allow.
postSentHeadRefused :: Client -> IO Bool
postSentHeadRefused cl = do
  sent <- prepareAs cl "post" >>= either (const (pure False))
    (\fd -> (== "POST") . vstring <$> getp fd "method")
  refused <- prepareAs cl "HEAD" >>= either
    (\(SdkException e) -> errCodeIs e "spec_method_allow") (const (pure False))
  pure (sent && refused)

-- The allow.method and allow.op lists the client resolved.
allowLists :: Client -> IO (String, String)
allowLists cl = do
  opts <- readIORef (clOptions cl)
  am <- getpathS opts "allow.method"
  ao <- getpathS opts "allow.op"
  pure (vstring am, vstring ao)

defaultAllowLists :: (String, String)
defaultAllowLists =
  ("GET,PUT,POST,PATCH,DELETE,OPTIONS", "create,update,patch,load,list,remove,command,direct,graphql")

takesDefaultAllow :: Value -> IO Bool
takesDefaultAllow sdkopts = do
  cl <- C.testSdk VNoval sdkopts
  lists <- allowLists cl
  ok <- postSentHeadRefused cl
  pure (lists == defaultAllowLists && ok)

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

  runTest c "make_point.allow_names_whole_ops" $ do
    let attempt allowop = do
          cl <- client; ctx <- mkCtx cl "load"
          parts <- ja [VStr "a"]
          point <- jo [("method", VStr "GET"), ("parts", parts)]
          pts <- ja [point]
          op <- newOperation =<< jo [("name", VStr "load"), ("points", pts)]
          writeIORef (cOp ctx) op
          ao <- jo [("op", VStr allowop)]; o <- jo [("allow", ao)]; writeIORef (cOptions ctx) o
          snd <$> makePointUtil ctx
    refused <- attempt "reload,unload"
    named <- attempt "list,\n LOAD"
    isRefused <- case refused of Just e -> errCodeIs e "point_op_allow"; Nothing -> pure False
    pure (isRefused && isNothing named)

  runTest c "make_context.patch_takes_data" $ do
    cl <- client
    ins <- mapM (\name -> do ctx <- mkCtx cl name; opInput <$> readIORef (cOp ctx)) ["patch", "update", "load"]
    pure (ins == ["data", "data", "match"])

  runTest c "make_spec.allow_names_whole_methods" $ do
    cl <- client; ctx <- mkCtx cl "update"
    parts <- ja [VStr "a"]
    point <- jo [("method", VStr "pu"), ("parts", parts)]
    writeIORef (cPoint ctx) point
    am <- jo [("method", VStr "GET,PUT")]; o <- jo [("allow", am), ("base", VStr "http://x")]
    writeIORef (cOptions ctx) o
    (_, merr) <- makeSpecUtil ctx
    case merr of Just e -> errCodeIs e "spec_method_allow"; Nothing -> pure False

  runTest c "prepare.allow_names_whole_methods" $ do
    am <- jo [("method", VStr "PUT,\n get")]; sdkopts <- jo [("allow", am)]
    cl <- C.testSdk VNoval sdkopts
    let prep m = do
          fa <- jo [("path", VStr "/a"), ("method", VStr m)]
          try (F.prepare cl fa) :: IO (Either SdkException Value)
        refused r = case r of
          Left (SdkException e) -> errCodeIs e "spec_method_allow"
          Right _ -> pure False
    got <- prep "get"
    sent <- case got of
      Right fd -> do m <- getp fd "method"; pure (vstring m == "GET")
      Left _ -> pure False
    post <- refused =<< prep "POST"
    pu <- refused =<< prep "PU"
    pure (sent && post && pu)

  runTest c "prepare.empty_allow_method_refuses" $ do
    am <- jo [("method", VStr "")]; sdkopts <- jo [("allow", am)]
    cl <- C.testSdk VNoval sdkopts
    fa <- jo [("path", VStr "/a"), ("method", VStr "get")]
    r <- try (F.prepare cl fa) :: IO (Either SdkException Value)
    case r of
      Left (SdkException e) -> errCodeIs e "spec_method_allow"
      Right _ -> pure False

  runTest c "prepare.null_allow_takes_default" $ do
    nm <- jo [("method", VNull)]; no <- jo [("op", VNull)]
    shapes <- sequence [jo [("allow", nm)], jo [("allow", no)], jo [("allow", VNull)]]
    and <$> mapM takesDefaultAllow shapes

  runTest c "prepare.undefined_allow_takes_default" $ do
    nm <- jo [("method", VNoval)]; no <- jo [("op", VNoval)]
    shapes <- sequence [jo [("allow", nm)], jo [("allow", no)], jo [("allow", VNoval)]]
    and <$> mapM takesDefaultAllow shapes

  -- The caller's allow map replaces a config allow that is null or not a map.
  runTest c "prepare.omitted_allow_key_takes_default" $ do
    let over cfgallow allow = do
          cfg <- makeConfig
          cfgopts <- getp cfg "options"
          setp cfgopts "allow" cfgallow
          sdkopts <- jo [("allow", allow)]
          F.sdkTest cfg makeFeature VNoval sdkopts
        opOnly cfgallow = do
          cl <- over cfgallow =<< jo [("op", VStr "load")]
          lists <- allowLists cl
          ok <- postSentHeadRefused cl
          pure (lists == (fst defaultAllowLists, "load") && ok)
    viaStr <- opOnly (VStr "x")
    viaNull <- opOnly VNull
    methodOnly <- allowLists =<< over (VStr "x") =<< jo [("method", VStr "GET")]
    pure (viaStr && viaNull && methodOnly == ("GET", snd defaultAllowLists))

  -- One options map builds two clients, the second over the model with its
  -- allow.method narrowed to GET. The first leaves the map as it was, down to
  -- its entity block, so the second resolves what a fresh map gives it and
  -- refuses a POST, and building the second leaves its model as it was.
  runTest c "options.reused_map_builds_independent_clients" $ do
    let literal = do
          ao <- jo [("op", VStr "create,load,list")]; hs <- jo [("x-caller", VStr "c1")]
          w <- jo [("note", VStr "c1")]; ent <- jo [("widget", w)]
          jo [("base", VStr "http://api.test"), ("allow", ao), ("headers", hs), ("entity", ent)]
        getOnly = do
          cfg <- makeConfig
          cfgopts <- getp cfg "options"
          setp cfgopts "allow" =<< jo [("method", VStr "GET")]
          pure cfg
        snapshot = jsonEncode True Nothing
        resolved cl = snapshot =<< readIORef (clOptions cl)
    shared <- literal
    before <- snapshot shared
    _ <- C.newSdk shared
    after <- snapshot shared
    model <- getOnly
    modelBefore <- snapshot model
    second <- F.makeClientBase model makeFeature shared
    modelAfter <- snapshot model
    freshModel <- getOnly
    fresh <- F.makeClientBase freshModel makeFeature =<< literal
    same <- (==) <$> resolved second <*> resolved fresh
    refused <- prepareAs second "post" >>= either
      (\(SdkException e) -> errCodeIs e "spec_method_allow") (const (pure False))
    pure (after == before && modelAfter == modelBefore && same && refused)

  runTest c "direct.allow_names_whole_ops" $ do
    ao <- jo [("op", VStr "indirect,reload")]; sdkopts <- jo [("allow", ao)]
    cl <- C.testSdk VNoval sdkopts
    fa <- jo [("path", VStr "/a")]
    res <- F.direct cl fa
    okv <- getp res "ok"
    errv <- getp res "err"
    pure (not (isTrueV okv) && "not allowed by SDK option allow.op" `isInfixOf` vstring errv)

  runTest c "direct.reports_unreadable_body" $ do
    let page = "<html>key NONJSON-SECRET-7f2c " ++ replicate 300 'x' ++ "</html>"
        fetchFn = VFunc (\_ _ _ _ -> do
          hm <- jo [("content-type", VStr "text/html")]
          jo [ ("status", VNum 200), ("statusText", VStr "OK"), ("headers", hm)
             , ("body", VStr page), ("json", jsonThunk VNoval), ("unreadable", VBool True) ])
    sys <- jo [("fetch", fetchFn)]
    hs <- jo [("user-agent", VStr "Probe/1.0")]
    opts <- jo [ ("base", VStr "http://nonjson.test"), ("apikey", VStr "NONJSON-SECRET-7f2c")
               , ("headers", hs), ("system", sys) ]
    cl <- C.newSdk opts
    fa <- jo [("path", VStr "/a")]
    res <- F.direct cl fa
    okv <- getp res "ok"
    errv <- getp res "err"
    code <- getp errv "code"; msg <- getp errv "message"
    let m = vstring msg
    pure (not (isTrueV okv) && vstring code == "response_content_type"
          && "expected JSON, got text/html (HTTP 200, content-type text/html, user-agent Probe/1.0, body: <html>key " `isInfixOf` m
          && not ("NONJSON-SECRET-7f2c" `isInfixOf` m) && "...)" `isSuffixOf` m)

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

  runTest c "test_mock.item_envelope" $ do
    cl <- client; ctx <- mkCtx cl "list"
    mergeSpec <- jo [("`$MERGE`", VStr "`.badge`")]
    restf <- ja [VStr "`$EACH`", VStr "body", mergeSpec]
    tm <- jo [("res", restf)]; point <- jo [("transform", tm)]
    writeIORef (cPoint ctx) point
    r1 <- jo [("id", VStr "b1")]; r2 <- jo [("id", VStr "b2")]
    out <- F.mockEnvelope ctx =<< ja [r1, r2]
    wrapped <- mapM (\i -> getp i "badge" >>= \r -> getp r "id") =<< listItems out
    back <- (\b -> transform INone b restf) =<< jo [("body", out)]
    ids <- mapM (\r -> getp r "id") =<< listItems back
    pure ([s | VStr s <- wrapped] == ["b1", "b2"] && [s | VStr s <- ids] == ["b1", "b2"])

  runTest c "test_mock.body_envelope" $ do
    cl <- client; ctx <- mkCtx cl "load"
    tm <- jo [("res", VStr "`body.item`")]; point <- jo [("transform", tm)]
    writeIORef (cPoint ctx) point
    out <- F.mockEnvelope ctx =<< jo [("id", VStr "i1")]
    i <- getp out "item" >>= \r -> getp r "id"
    pure (case i of VStr "i1" -> True; _ -> False)

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

  -- A body the transport marks as not JSON is named by its label.
  let unreadableErr status ctype body = do
        cl <- client; ctx <- mkCtx cl "load"
        sp <- fullSpec
        sh <- getp sp "headers"; setp sh "user-agent" (VStr "Probe/1.0")
        writeIORef (cSpec ctx) sp
        hm <- emptyMap
        mapM_ (\t -> setp hm "content-type" (VStr t)) ctype
        r <- newResponse =<< jo [ ("status", vint status), ("statusText", VStr (if status < 400 then "OK" else "ERR"))
                                 , ("headers", hm), ("json", jsonThunk VNoval), ("body", VStr body)
                                 , ("unreadable", VBool True) ]
        writeIORef (cResponse ctx) r
        res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
        _ <- makeResponseUtil ctx
        rv <- readIORef (cResult ctx)
        e <- getp rv "err"
        code <- errCode e; msg <- errMsg e
        pure (code, msg)

  runTest c "make_response.unreadable_json_label" $ do
    (code, msg) <- unreadableErr 200 (Just "application/json") "{\"a\": "
    pure (code == "response_json_invalid"
          && "body is not valid JSON (HTTP 200, content-type application/json, user-agent Probe/1.0, body: {\"a\":)" `isInfixOf` msg)

  runTest c "make_response.unreadable_no_label" $ do
    (code, msg) <- unreadableErr 200 Nothing "not json"
    pure (code == "response_json_invalid" && "content-type none" `isInfixOf` msg)

  runTest c "make_response.unreadable_other_label" $ do
    (code, msg) <- unreadableErr 200 (Just "text/html") "<p>\n  challenge </p>"
    pure (code == "response_content_type" && "expected JSON, got text/html" `isInfixOf` msg
          && "body: <p> challenge </p>)" `isInfixOf` msg)

  runTest c "make_response.unreadable_http_failure" $ do
    (code, msg) <- unreadableErr 503 (Just "text/html") "<p>down</p>"
    pure (code == "request_status"
          && "request: 503: ERR (HTTP 503, content-type text/html, user-agent Probe/1.0, body: <p>down</p>)" `isInfixOf` msg)

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
