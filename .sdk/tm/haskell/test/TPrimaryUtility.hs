-- Primary utility tests. One focused test per primary pipeline utility,
-- driving each through the client utility / SdkRuntime directly (the rust
-- donor tests/primary_utility_test.rs analog). Verifies the shared `primary`
-- subtree is present, then exercises prepare*/make*/result*/transform*/
-- feature*/fetcher/clean/done/makeError with deterministic assertions.

{-# LANGUAGE ScopedTypeVariables #-}

module TPrimaryUtility (tests) where

import Control.Exception (try)
import Control.Monad (when)
import Data.IORef
import Data.Maybe (isNothing)

import VoxgigStruct (Value (..), ismap, emptyMap, emptyList, isNoval)
import SdkTypes
import SdkHelpers
import SdkRuntime
import qualified SdkClient as C
import Testutil

mkCtx :: Client -> String -> IO Context
mkCtx cl opname = do
  root <- readIORef (clRootctx cl)
  makeContextImpl (defaultCtxSpec { csOpname = Just opname, csClient = Just cl, csUtility = Just (clUtility cl) }) root

mkCtxCtrl :: Client -> String -> Value -> IO Context
mkCtxCtrl cl opname ctrl = do
  root <- readIORef (clRootctx cl)
  makeContextImpl (defaultCtxSpec { csOpname = Just opname, csClient = Just cl, csUtility = Just (clUtility cl), csCtrl = Just ctrl }) root

-- A ctx with a fully-populated point + match/reqmatch (rust make_test_full_ctx).
mkFullCtx :: Client -> IO Context
mkFullCtx cl = do
  ctx <- mkCtx cl "load"
  idp <- jo [("name", VStr "id"), ("reqd", VBool True)]
  pl <- ja [idp]
  argsm <- jo [("params", pl)]
  partsL <- ja [VStr "items", VStr "{id}"]
  paramsL <- ja [VStr "id"]
  al <- emptyMap; sel <- emptyMap; tr <- emptyMap
  point <- jo [ ("parts", partsL), ("args", argsm), ("params", paramsL)
              , ("alias", al), ("select", sel), ("active", VBool True), ("transform", tr) ]
  writeIORef (cPoint ctx) point
  m <- jo [("id", VStr "item01")]; writeIORef (cMatch ctx) m
  rm <- jo [("id", VStr "item01")]; writeIORef (cReqmatch ctx) rm
  pure ctx

fullSpec :: IO Value
fullSpec = do
  pm <- emptyMap; qm <- emptyMap; hm <- emptyMap
  newSpec =<< jo [ ("base", VStr "http://h"), ("prefix", VStr ""), ("suffix", VStr "")
                 , ("path", VStr "a"), ("method", VStr "GET"), ("params", pm)
                 , ("query", qm), ("headers", hm), ("step", VStr "s") ]

namedFeature :: String -> Value -> IO Feature
namedFeature nm opts = do
  active <- newIORef True; fopts <- newIORef opts
  pure Feature { fName = nm, fVersion = "0.0.1", fActive = active, fOptions = fopts, fInit = \_ _ -> pure (), fHook = \_ _ -> pure () }

errCodeIs :: Value -> String -> IO Bool
errCodeIs e code = do c <- errCode e; pure (c == code)

tests :: Counters -> Value -> IO ()
tests c alltests = do

  runTest c "primary.subtree_present" $ do
    primary <- getp alltests "primary"
    pure (ismap primary)

  runTest c "primary.utility_exists" $ do
    cl <- C.testSdk0
    ctx <- mkCtx cl "load"
    m <- prepareMethodUtil ctx
    h <- prepareHeadersUtil ctx
    q <- prepareQueryUtil ctx
    p <- prepareParamsUtil ctx
    raw <- emptyMap; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    cv <- cleanUtil ctx (VStr "x")
    pure (m == "GET" && ismap h && ismap q && ismap p && ismap o && vstring cv == "x")

  runTest c "primary.clean_identity" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    r <- cleanUtil ctx (VStr "x")
    pure (vstring r == "x")

  runTest c "primary.clean_map" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    v <- jo [("key", VStr "secret"), ("name", VStr "test")]
    r <- cleanUtil ctx v
    pure (ismap r)

  runTest c "primary.done_returns_resdata" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    res <- newResult =<< jo [("ok", VBool True), ("resdata", VNum 42)]; writeIORef (cResult ctx) res
    r <- doneUtil ctx
    pure (case r of VNum n -> n == 42; _ -> False)

  runTest c "primary.make_error_no_throw" $ do
    cl <- C.testSdk0; ctrl <- jo [("throw_err", VBool False)]
    ctx <- mkCtxCtrl cl "load" ctrl
    res <- newResult =<< jo [("ok", VBool False), ("resdata", VStr "fallback")]; writeIORef (cResult ctx) res
    r <- makeErrorUtil ctx Nothing
    pure (vstring r == "fallback")

  runTest c "primary.make_error_throws_by_default" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    res <- newResult =<< jo [("ok", VBool False)]; writeIORef (cResult ctx) res
    r <- try (makeErrorUtil ctx Nothing) :: IO (Either SdkException Value)
    pure (case r of Left _ -> True; Right _ -> False)

  runTest c "primary.feature_add_appends" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    start <- readIORef (clFeatures cl) >>= \fs -> pure (length fs)
    f <- namedFeature "aaa" VNoval
    featureAddUtil ctx f
    len2 <- readIORef (clFeatures cl) >>= \fs -> pure (length fs)
    pure (len2 == start + 1)

  runTest c "primary.feature_hook_dispatches" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    called <- newIORef False
    active <- newIORef True; fopts <- newIORef VNoval
    let feat = Feature { fName = "hookfeat", fVersion = "0.0.1", fActive = active, fOptions = fopts
                       , fInit = \_ _ -> pure (), fHook = \name _ -> when (name == "TestHook") (writeIORef called True) }
    writeIORef (clFeatures cl) [feat]
    featureHookUtil ctx "TestHook"
    readIORef called

  runTest c "primary.feature_init_active" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    fo <- jo [("active", VBool True)]; featm <- jo [("initfeat", fo)]; opts <- jo [("feature", featm)]
    writeIORef (cOptions ctx) opts
    initCalled <- newIORef False
    active <- newIORef True; fopts <- newIORef VNoval
    let feat = Feature { fName = "initfeat", fVersion = "0.0.1", fActive = active, fOptions = fopts
                       , fInit = \_ _ -> writeIORef initCalled True, fHook = \_ _ -> pure () }
    featureInitUtil ctx feat
    readIORef initCalled

  runTest c "primary.feature_init_inactive" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    fo <- jo [("active", VBool False)]; featm <- jo [("nofeat", fo)]; opts <- jo [("feature", featm)]
    writeIORef (cOptions ctx) opts
    initCalled <- newIORef False
    active <- newIORef False; fopts <- newIORef VNoval
    let feat = Feature { fName = "nofeat", fVersion = "0.0.1", fActive = active, fOptions = fopts
                       , fInit = \_ _ -> writeIORef initCalled True, fHook = \_ _ -> pure () }
    featureInitUtil ctx feat
    called <- readIORef initCalled
    pure (not called)

  runTest c "primary.fetcher_blocked_test_mode" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    hm <- emptyMap; fd <- jo [("method", VStr "GET"), ("headers", hm)]
    (_, merr) <- fetcherUtil ctx "http://x" fd
    case merr of Just e -> errCodeIs e "fetch_mode_block"; Nothing -> pure False

  runTest c "primary.fetcher_live_calls_system_fetch" $ do
    recRef <- newIORef ([] :: [Value])
    let fetchFn = VFunc (\_ args _ _ -> do modifyIORef recRef (++ [args]); jo [("status", VNum 200), ("statusText", VStr "OK")])
    sys <- jo [("fetch", fetchFn)]; opts <- jo [("system", sys)]
    cl <- C.newSdk opts
    ctx <- mkCtx cl "load"
    hm <- emptyMap; fd <- jo [("method", VStr "GET"), ("headers", hm)]
    (_, merr) <- fetcherUtil ctx "http://example.com/test" fd
    calls <- readIORef recRef
    first <- case calls of (x : _) -> vlistItems x; [] -> pure []
    let url = case first of (u : _) -> vstring u; [] -> ""
    pure (isNothing merr && length calls == 1 && url == "http://example.com/test")

  runTest c "primary.make_context_inherits_options" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    opts <- readIORef (cOptions ctx)
    pure (ismap opts)

  runTest c "primary.make_context_has_id" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    pure (not (null (cId ctx)))

  runTest c "primary.make_fetch_def_basic" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    writeIORef (cResult ctx) VNoval
    sp <- newSpec =<< jo [("base", VStr "http://localhost:8080"), ("path", VStr "items/x"), ("method", VStr "GET")]
    writeIORef (cSpec ctx) sp
    (fd, merr) <- makeFetchDefUtil ctx
    method <- getp fd "method"; url <- getStrD fd "url" ""
    pure (isNothing merr && vstring method == "GET" && substrContains url "items/x")

  runTest c "primary.make_fetch_def_with_body" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    writeIORef (cResult ctx) VNoval
    b <- jo [("name", VStr "test")]
    sp <- newSpec =<< jo [("base", VStr "http://h"), ("path", VStr "items"), ("method", VStr "POST"), ("body", b)]
    writeIORef (cSpec ctx) sp
    (fd, merr) <- makeFetchDefUtil ctx
    bs <- getp fd "body"
    pure (isNothing merr && (case bs of VStr s -> substrContains s "name"; _ -> False))

  runTest c "primary.make_options_map" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    raw <- emptyMap; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    pure (ismap o)

  runTest c "primary.make_options_derives_clean_keyre" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    raw <- emptyMap; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    kr <- getpathS o "__derived__.clean.keyre"
    pure (case kr of VStr s -> not (null s); _ -> False)

  runTest c "primary.make_request_guard_no_spec" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    writeIORef (cSpec ctx) VNoval
    (_, merr) <- makeRequestUtil ctx
    case merr of Just e -> errCodeIs e "request_no_spec"; Nothing -> pure False

  runTest c "primary.make_response_2xx_parses_body" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    d <- jo [("v", VNum 1)]
    resp <- newResponse =<< jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk d), ("body", VStr "raw")]
    writeIORef (cResponse ctx) resp
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    (_, merr) <- makeResponseUtil ctx
    rv <- readIORef (cResult ctx); ok <- getp rv "ok"; bv <- getp rv "body" >>= \b -> getp b "v"
    pure (isNothing merr && isTrueV ok && (case bv of VNum n -> n == 1; _ -> False))

  runTest c "primary.make_result_basic" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    sp <- fullSpec; writeIORef (cSpec ctx) sp
    rd <- jo [("id", VStr "item01")]
    res <- newResult =<< jo [("ok", VBool True), ("status", VNum 200), ("resdata", rd)]; writeIORef (cResult ctx) res
    (ro, merr) <- makeResultUtil ctx
    st <- getp ro "status"
    pure (isNothing merr && toInt st == 200)

  runTest c "primary.make_result_no_spec" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    writeIORef (cSpec ctx) VNoval
    res <- newResult =<< jo [("ok", VBool True)]; writeIORef (cResult ctx) res
    (_, merr) <- makeResultUtil ctx
    case merr of Just e -> errCodeIs e "result_no_spec"; Nothing -> pure False

  runTest c "primary.make_result_no_result" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    sp <- newSpec =<< jo [("step", VStr "start")]; writeIORef (cSpec ctx) sp
    writeIORef (cResult ctx) VNoval
    (_, merr) <- makeResultUtil ctx
    case merr of Just e -> errCodeIs e "result_no_result"; Nothing -> pure False

  runTest c "primary.make_spec_basic" $ do
    cl <- C.testSdk0; ctx <- mkFullCtx cl
    (sp, merr) <- makeSpecUtil ctx
    method <- getp sp "method"; path <- getStrD sp "path" ""
    pure (isNothing merr && vstring method == "GET" && path == "items/{id}")

  runTest c "primary.make_point_basic" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    parts <- ja [VStr "items", VStr "{id}"]
    point <- jo [("method", VStr "GET"), ("parts", parts)]
    pts <- ja [point]
    op <- newOperation =<< jo [("name", VStr "load"), ("points", pts)]
    writeIORef (cOp ctx) op
    (_, merr) <- makePointUtil ctx
    pt <- readIORef (cPoint ctx)
    pure (isNothing merr && ismap pt)

  runTest c "primary.make_url_basic" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    p <- jo [("id", VStr "item01")]
    sp <- newSpec =<< jo [("base", VStr "http://h"), ("path", VStr "items/{id}"), ("params", p), ("method", VStr "GET")]
    writeIORef (cSpec ctx) sp
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    (urlV, merr) <- makeUrlUtil ctx
    pure (isNothing merr && substrContains (vstring urlV) "http://h/items/item01")

  runTest c "primary.operator_basic" $ do
    pts <- emptyList
    op <- newOperation =<< jo [("entity", VStr "planet"), ("name", VStr "load"), ("input", VStr "match"), ("points", pts)]
    pure (opEntity op == "planet" && opName op == "load" && opInput op == "match")

  runTest c "primary.param_basic" $ do
    cl <- C.testSdk0; ctx <- mkFullCtx cl
    v <- paramUtil ctx (VStr "id")
    pure (vstring v == "item01")

  runTest c "primary.prepare_auth_apikey" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    ap <- jo [("prefix", VStr "Bearer")]; o <- jo [("apikey", VStr "K"), ("auth", ap)]; writeIORef (clOptions cl) o
    hm <- emptyMap; sp <- newSpec =<< jo [("headers", hm)]; writeIORef (cSpec ctx) sp
    _ <- prepareAuthUtil ctx
    spv <- readIORef (cSpec ctx); h <- getp spv "headers"; av <- getp h "authorization"
    pure (vstring av == "Bearer K")

  runTest c "primary.prepare_body_match_is_noval" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    b <- prepareBodyUtil ctx
    pure (isNoval b)

  runTest c "primary.prepare_headers_map" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    h <- prepareHeadersUtil ctx
    pure (ismap h)

  runTest c "primary.prepare_method_get" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    m <- prepareMethodUtil ctx
    pure (m == "GET")

  runTest c "primary.prepare_method_post" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "create"
    m <- prepareMethodUtil ctx
    pure (m == "POST")

  runTest c "primary.prepare_params_map" $ do
    cl <- C.testSdk0; ctx <- mkFullCtx cl
    p <- prepareParamsUtil ctx
    pure (ismap p)

  runTest c "primary.prepare_path_basic" $ do
    cl <- C.testSdk0; ctx <- mkFullCtx cl
    p <- preparePathUtil ctx
    pure (p == "items/{id}")

  runTest c "primary.prepare_path_single" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    parts <- ja [VStr "items"]
    point <- jo [("parts", parts)]
    writeIORef (cPoint ctx) point
    p <- preparePathUtil ctx
    pure (p == "items")

  runTest c "primary.prepare_query_map" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    q <- prepareQueryUtil ctx
    pure (ismap q)

  runTest c "primary.result_basic_sets_status" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    resp <- newResponse =<< jo [("status", VNum 200), ("statusText", VStr "OK")]; writeIORef (cResponse ctx) resp
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    resultBasicUtil ctx
    rv <- readIORef (cResult ctx); st <- getp rv "status"
    pure (toInt st == 200)

  runTest c "primary.result_body_parses_json" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    d <- jo [("a", VNum 1)]
    resp <- newResponse =<< jo [("status", VNum 200), ("json", jsonThunk d), ("body", VStr "raw")]; writeIORef (cResponse ctx) resp
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    resultBodyUtil ctx
    rv <- readIORef (cResult ctx); a <- getp rv "body" >>= \b -> getp b "a"
    pure (case a of VNum n -> n == 1; _ -> False)

  runTest c "primary.result_headers_copies" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    hm <- jo [("x-a", VStr "1")]
    resp <- newResponse =<< jo [("status", VNum 200), ("headers", hm)]; writeIORef (cResponse ctx) resp
    res <- newResult =<< emptyMap; writeIORef (cResult ctx) res
    resultHeadersUtil ctx
    rv <- readIORef (cResult ctx); h <- getp rv "headers"; xa <- getp h "x-a"
    pure (vstring xa == "1")

  runTest c "primary.transform_request_sets_step" $ do
    cl <- C.testSdk0; ctx <- mkFullCtx cl
    sp <- newSpec =<< jo [("method", VStr "GET")]; writeIORef (cSpec ctx) sp
    _ <- transformRequestUtil ctx
    spv <- readIORef (cSpec ctx); step <- getStrD spv "step" ""
    pure (step == "reqform")

  runTest c "primary.transform_response_sets_step" $ do
    cl <- C.testSdk0; ctx <- mkFullCtx cl
    sp <- newSpec =<< jo [("method", VStr "GET")]; writeIORef (cSpec ctx) sp
    res <- newResult =<< jo [("ok", VBool True)]; writeIORef (cResult ctx) res
    _ <- transformResponseUtil ctx
    spv <- readIORef (cSpec ctx); step <- getStrD spv "step" ""
    pure (step == "resform")

  runTest c "primary.new_sdk_mode_live" $ do
    cl <- C.newSdk VNoval
    m <- readIORef (clMode cl)
    pure (m == "live")
