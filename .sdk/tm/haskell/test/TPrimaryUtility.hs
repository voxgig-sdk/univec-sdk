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

import VoxgigStruct (Value (..), ismap, emptyMap, emptyList, isNoval, keysof)
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

-- A ctx for the given op whose point, match and data are the given maps,
-- on a client whose options send the given default headers.
argCtx :: String -> [(String, Value)] -> [(String, Value)] -> [(String, Value)] -> [(String, Value)] -> IO Context
argCtx opname headers point reqmatch reqdata = do
  cl <- C.testSdk0
  hs <- jo headers
  opts <- jo [("headers", hs)]
  writeIORef (clOptions cl) opts
  ctx <- mkCtx cl opname
  p <- jo point; writeIORef (cPoint ctx) p
  rm <- jo reqmatch; writeIORef (cReqmatch ctx) rm
  rd <- jo reqdata; writeIORef (cReqdata ctx) rd
  pure ctx

argDef :: (String, String) -> IO Value
argDef (name, orig) = jo [("name", VStr name), ("orig", VStr orig)]

cookieArgs :: IO Value
cookieArgs = do
  h <- ja =<< mapM argDef [("x_trace", "X-Trace")]
  c <- ja =<< mapM argDef [("session_id", "SESSIONID"), ("theme", "theme"), ("prefs", "prefs")]
  jo [("header", h), ("cookie", c)]

queryArgs :: IO Value
queryArgs = do
  p <- ja =<< mapM (\n -> jo [("name", VStr n)]) ["id"]
  q <- ja =<< mapM argDef [("page_size", "pageSize"), ("lang", "lang"), ("trace", "trace")]
  h <- ja =<< mapM argDef [("x_trace", "X-Trace"), ("trace", "trace")]
  c <- ja =<< mapM argDef [("session_id", "SESSIONID"), ("lang", "lang")]
  jo [("params", p), ("query", q), ("header", h), ("cookie", c)]

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

  runTest c "primary.make_options_derives_clean_config" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    raw <- jo [("apikey", VStr "SECRET-abcdef")]; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    keys <- getpathS o "__derived__.clean.keys"
    nkeys <- case keys of VList _ -> length <$> vlistItems keys; _ -> pure 0
    values <- getpathS o "__derived__.clean.values"
    vals <- case values of VList _ -> vlistItems values; _ -> pure []
    mask <- getpathS o "__derived__.clean.mask"
    pure (nkeys > 0 && any (\v -> vstring v == "SECRET-abcdef") vals && vstring mask == "[redacted]")

  runTest c "primary.clean_masks_registered_and_named" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    raw <- jo [("apikey", VStr "SECRET-abcdef")]; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    writeIORef (cOptions ctx) o
    h <- jo [("authorization", VStr "Bearer SECRET-abcdef"), ("x-custom-token", VStr "tok-123456"), ("accept", VStr "json")]
    v <- jo [("headers", h), ("note", VStr "key SECRET-abcdef sent")]
    r <- cleanUtil ctx v
    rh <- getp r "headers"
    auth <- getp rh "authorization"; tok <- getp rh "x-custom-token"; acc <- getp rh "accept"; note <- getp r "note"
    orig <- getp h "authorization"
    pure (vstring auth == "[redacted]" && vstring tok == "[redacted]" && vstring acc == "json"
          && vstring note == "key [redacted] sent" && vstring orig == "Bearer SECRET-abcdef")

  runTest c "primary.make_error_cleans_the_code" $ do
    cl <- C.testSdk0
    ctrl <- jo [("throw", VBool False)]
    ctx <- mkCtxCtrl cl "load" ctrl
    raw <- emptyMap; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    writeIORef (cOptions ctx) o
    cleanAddUtil ctx (VStr "CODE-SECRET-12")
    e <- mkErr "refused_CODE-SECRET-12" "refused"
    _ <- makeErrorUtil ctx (Just e)
    made <- (`getp` "err") =<< readIORef (cCtrl ctx)
    code <- getp made "code"
    pure (vstring code == "refused_[redacted]")

  runTest c "primary.clean_with_a_huge_hint_still_masks" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    hc <- jo [("hint", VStr "5000000000000000000")]
    raw <- jo [("apikey", VStr "HINT-SECRET-abcdef"), ("clean", hc)]; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    writeIORef (cOptions ctx) o
    s <- cleanUtil ctx (VStr "k HINT-SECRET-abcdef")
    pure (vstring s == "k [redacted]")

  runTest c "primary.clean_masks_registered_property_names" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    raw <- emptyMap; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    writeIORef (cOptions ctx) o
    cleanAddUtil ctx (VStr "ZZVAL-abc123")
    cleanAddUtil ctx (VStr "ZZVAL-xyz789")
    v <- jo [("ZZVAL-abc123", VNum 1), ("ZZVAL-xyz789", VNum 2), ("plain", VNum 3)]
    r <- cleanUtil ctx v
    ks <- case r of VMap ref -> map fst <$> readIORef ref; _ -> pure []
    pure (ks == ["[redacted]", "[redacted]#1", "plain"])

  runTest c "primary.clean_add_sensitive_every_scalar" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    raw <- emptyMap; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    writeIORef (cOptions ctx) o
    apikey <- jo [("value", VStr "NESTED-SECRET-1")]
    listed <- ja [VStr "LISTED-SECRET-2"]
    hdrs <- jo [("X-Api-Token", listed)]
    loop <- jo [("token", VStr "LOOP-SECRET-3")]
    setp loop "self" loop
    v <- jo [("apikey", apikey), ("headers", hdrs), ("secret", VNum 123456789)
            , ("name", VStr "not-a-secret"), ("loop", loop)]
    cleanAddSensitiveUtil ctx v
    values <- getpathS o "__derived__.clean.values"
    vals <- case values of VList _ -> map vstring <$> vlistItems values; _ -> pure []
    pure (all (`elem` vals) ["NESTED-SECRET-1", "LISTED-SECRET-2", "123456789", "LOOP-SECRET-3"]
          && "not-a-secret" `notElem` vals)

  runTest c "primary.clean_honours_the_config_clean_block" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    cfgclean <- jo [("keys", VStr "zzsens"), ("values", VStr "CONFIG-SEEDED-1")]
    cfgopts <- jo [("clean", cfgclean)]
    config <- jo [("options", cfgopts)]
    writeIORef (cConfig ctx) config
    uclean <- jo [("values", VStr "CALLER-SEEDED-2")]
    raw <- jo [("clean", uclean)]; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    writeIORef (cOptions ctx) o
    s <- cleanUtil ctx (VStr "a CONFIG-SEEDED-1 b CALLER-SEEDED-2")
    m <- jo [("my_zzsens", VStr "x"), ("other", VStr "y")]
    mc <- cleanUtil ctx m
    sens <- getp mc "my_zzsens"; other <- getp mc "other"
    seeded <- getp cfgclean "values"
    pure (vstring s == "a [redacted] b [redacted]" && vstring sens == "[redacted]"
          && vstring other == "y" && vstring seeded == "CONFIG-SEEDED-1")

  runTest c "primary.feature_names_do_not_make_settings_sensitive" $ do
    cl <- C.testSdk0; ctx <- mkCtx cl "load"
    sec <- jo [("active", VBool False), ("kind", VStr "vaultish"), ("token", VStr "REAL-TOKEN-1")]
    fm <- jo [("secrets", sec)]
    raw <- jo [("feature", fm)]; writeIORef (cOptions ctx) raw
    o <- makeOptionsUtil ctx
    values <- getpathS o "__derived__.clean.values"
    vals <- case values of VList _ -> map vstring <$> vlistItems values; _ -> pure []
    pure ("REAL-TOKEN-1" `elem` vals && "vaultish" `notElem` vals)

  runTest c "primary.entity_blocks_are_not_read" $ do
    let seeded kvs = do
          rec <- jo [("id", VStr "ZZTOKEN01"), ("note", VStr "PLAINRECORD-t5r3e1w9")]
          ids <- jo [("ZZTOKEN01", rec)]
          block <- jo kvs; setp block "entity" =<< jo [("zztoken", ids)]; pure block
        feature = do
          token <- jo [("active", VBool False), ("apitoken", VStr "FEATTOKEN-z9y8x7w6")]
          test <- seeded [("active", VBool False)]
          pure [("zzfeat", token), ("test", test)]
        named (n, f) = do setp f "name" (VStr n); pure f
    fmap and $ mapM (\mkFeature -> do
      cl <- C.testSdk0; ctx <- mkCtx cl "load"
      alias <- jo [("zzkey", VStr "PLAINALIAS-m2n4b6v8")]
      ent <- jo [("zztoken", VNull)]; setp ent "zztoken" =<< jo [("alias", alias)]
      test <- seeded []
      fv <- mkFeature
      raw <- jo [("feature", fv), ("entity", ent), ("test", test)]; writeIORef (cOptions ctx) raw
      o <- makeOptionsUtil ctx
      writeIORef (cOptions ctx) o
      values <- getpathS o "__derived__.clean.values"
      vals <- case values of VList _ -> map vstring <$> vlistItems values; _ -> pure []
      record <- cleanUtil ctx (VStr "record PLAINRECORD-t5r3e1w9")
      aliased <- cleanUtil ctx (VStr "alias PLAINALIAS-m2n4b6v8")
      pure ("FEATTOKEN-z9y8x7w6" `elem` vals
            && all (`notElem` vals) ["ZZTOKEN01", "PLAINRECORD-t5r3e1w9", "PLAINALIAS-m2n4b6v8"]
            && vstring record == "record PLAINRECORD-t5r3e1w9"
            && vstring aliased == "alias PLAINALIAS-m2n4b6v8"))
      [feature >>= jo, feature >>= mapM named >>= ja]

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

  -- A header, cookie or query argument travels where the definition declares
  -- it. Port of the ts pathquery.test.ts cases.
  runTest c "primary.prepare_headers_header_arg_replaces_default" $ do
    hdefs <- ja =<< mapM argDef [("idempotency_key", "Idempotency-Key"), ("page_size", "Page-Size")]
    args <- jo [("header", hdefs)]
    ctx <- argCtx "load" [("Idempotency-Key", VStr "default"), ("user-agent", VStr "sdk")]
      [("args", args)] [("idempotency_key", VStr "k1")] [("page_size", VStr "3")]
    h <- prepareHeadersUtil ctx
    k <- getp h "idempotency-key"; old <- getp h "Idempotency-Key"
    ps <- getp h "page-size"; ua <- getp h "user-agent"
    pure (vstring k == "k1" && isNoval old && vstring ps == "3" && vstring ua == "sdk")

  runTest c "primary.prepare_headers_cookie_pairs" $ do
    args <- cookieArgs
    theme <- ja [VStr "dark", VStr "x y"]
    prefs <- jo [("lang", VStr "en gb"), ("size", VStr "2")]
    ctx <- argCtx "load" [] [("args", args)] [("session_id", VStr "a b;c,d")]
      [("theme", theme), ("prefs", prefs)]
    h <- prepareHeadersUtil ctx
    cv <- getp h "cookie"
    pure (vstring cv == "SESSIONID=a%20b%3Bc%2Cd; theme=dark; theme=x%20y; lang=en%20gb; size=2")

  runTest c "primary.prepare_headers_cookie_replaces_same_name_keeps_others_whole" $ do
    args <- cookieArgs
    ctx <- argCtx "load" [("Cookie", VStr "SESSIONID=old; session=a=b&theme=old ;lang=en"), ("user-agent", VStr "sdk")]
      [("args", args)] [("session_id", VStr "s1")] [("theme", VStr "dark")]
    h <- prepareHeadersUtil ctx
    cv <- getp h "cookie"; old <- getp h "Cookie"; ua <- getp h "user-agent"
    pure (vstring cv == "session=a=b&theme=old; lang=en; SESSIONID=s1; theme=dark"
      && isNoval old && vstring ua == "sdk")

  runTest c "primary.prepare_headers_cookie_map_replaces_encoded_key" $ do
    args <- cookieArgs
    prefs <- jo [("x y", VStr "new")]
    ctx <- argCtx "load" [("Cookie", VStr "x%20y=old; theme=dark")] [("args", args)]
      [("session_id", VStr "s1")] [("prefs", prefs)]
    h <- prepareHeadersUtil ctx
    cv <- getp h "cookie"
    pure (vstring cv == "theme=dark; SESSIONID=s1; x%20y=new")

  runTest c "primary.prepare_headers_null_cookie_leaves_headers" $ do
    args <- cookieArgs
    ctx <- argCtx "load" [("Cookie", VStr "lang=en")] [("args", args)] [("session_id", VNull)] []
    h <- prepareHeadersUtil ctx
    cv <- getp h "Cookie"; lc <- getp h "cookie"
    pure (vstring cv == "lang=en" && isNoval lc)

  runTest c "primary.prepare_headers_media" $ do
    res <- jo [("kind", VStr "json"), ("media", VStr "application/vnd.api+json")]
    body <- jo [("kind", VStr "json"), ("media", VStr "application/vnd.api+json")]
    ctx <- argCtx "load" [("content-type", VStr "application/json")]
      [("response", res), ("body", body)] [] []
    h <- prepareHeadersUtil ctx
    a <- getp h "accept"; ct <- getp h "content-type"
    ctx2 <- argCtx "load" [("Accept", VStr "text/plain"), ("content-type", VStr "text/plain")]
      [("response", res), ("body", body)] [] []
    h2 <- prepareHeadersUtil ctx2
    a2 <- getp h2 "Accept"; la2 <- getp h2 "accept"; ct2 <- getp h2 "content-type"
    pure (vstring a == "application/vnd.api+json" && vstring ct == "application/vnd.api+json"
      && vstring a2 == "text/plain" && isNoval la2 && vstring ct2 == "text/plain")

  runTest c "primary.prepare_query_routes_arguments" $ do
    args <- queryArgs
    paramsL <- ja [VStr "id"]
    ctx <- argCtx "load" [] [("params", paramsL), ("args", args)]
      [ ("id", VStr "i1"), ("x_trace", VStr "t1"), ("session_id", VStr "s1"), ("q", VStr "x")
      , ("$action", VStr "a"), ("page_size", VStr "3"), ("lang", VStr "en"), ("trace", VStr "t1") ] []
    q <- prepareQueryUtil ctx
    ks <- keysof q
    ps <- getp q "pageSize"; l <- getp q "lang"; t <- getp q "trace"; qq <- getp q "q"
    pure (ks == ["lang", "pageSize", "q", "trace"] && vstring ps == "3" && vstring l == "en"
      && vstring t == "t1" && vstring qq == "x")

  runTest c "primary.prepare_query_from_data" $ do
    args <- queryArgs
    ctx <- argCtx "create" [] [("args", args)] [] [("page_size", VStr "3"), ("lang", VStr "en")]
    q <- prepareQueryUtil ctx
    ks <- keysof q; ps <- getp q "pageSize"
    pure (ks == ["lang", "pageSize"] && vstring ps == "3")

  runTest c "primary.transform_request_omits_routed_arguments" $ do
    args <- queryArgs
    tr <- jo [("req", VStr "`reqdata`")]
    ctx <- argCtx "create" [] [("args", args), ("transform", tr)] []
      [ ("x_trace", VStr "t1"), ("session_id", VStr "s1"), ("page_size", VStr "2")
      , ("title", VStr "T"), ("$action", VStr "a") ]
    b <- transformRequestUtil ctx
    ks <- keysof b
    t <- getp b "title"
    pure (ks == ["title"] && vstring t == "T")

  runTest c "primary.transform_request_keeps_field_arguments" $ do
    tr <- jo [("req", VStr "`reqdata`")]
    kept <- mapM (\kind -> do
      locale <- jo [("name", VStr "locale"), ("orig", VStr "Locale"), ("field", VBool True)]
      session <- argDef ("session_id", "SESSIONID")
      args <- jo . (\defs -> [(kind, defs)]) =<< ja [locale, session]
      ctx <- argCtx "create" [] [("args", args), ("transform", tr)] []
        [("name", VStr "n"), ("locale", VStr "en"), ("session_id", VStr "s1")]
      b <- transformRequestUtil ctx
      ks <- keysof b
      l <- getp b "locale"
      pure (ks == ["locale", "name"] && vstring l == "en")) ["header", "cookie", "query"]
    pure (and kept)

  runTest c "primary.prepare_body_raw" $ do
    body <- jo [("kind", VStr "raw"), ("media", VStr "text/plain")]
    ctx <- argCtx "create" [] [("body", body)] [] [("$body", VStr "hello")]
    b <- prepareBodyUtil ctx
    pure (vstring b == "hello")

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
