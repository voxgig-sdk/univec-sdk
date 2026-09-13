-- Offline feature-test harness (mirrors the dynamic donors' feature_harness).
--
-- Drives each real generated feature through a faithful miniature of the
-- operation pipeline against a configurable mock transport — the same hook
-- order and short-circuit rules as the generic op runner, but with no live
-- server and no API-specific fixtures. Features come from SdkConfig.makeFeature
-- so only features present in this SDK are exercised (see hasFeature).

{-# LANGUAGE ScopedTypeVariables #-}

module Harness where

import Control.Exception (SomeException, try)
import Data.IORef
import Data.List (sort)

import VoxgigStruct
  ( Value (..), emptyMap, emptyList, mkList, keysof, clone, ismap, escurl, vint
  , isNoval, isNullish, setprop )
import SdkTypes
import SdkHelpers
import SdkRuntime
import qualified SdkConfig as Cfg

-- ----- virtual clock -----

data Clock = Clock { clkT :: IORef Double }

makeClock :: IO Clock
makeClock = Clock <$> newIORef 0

clockNow :: Clock -> IO Double
clockNow c = readIORef (clkT c)

clockAdvance :: Clock -> Double -> IO ()
clockAdvance c ms = modifyIORef' (clkT c) (+ ms)

clockNowFn :: Clock -> Value
clockNowFn c = VFunc (\_ _ _ _ -> VNum <$> readIORef (clkT c))

clockSleepFn :: Clock -> Value
clockSleepFn c = VFunc (\_ v _ _ -> do
  case v of VNum ms -> modifyIORef' (clkT c) (+ (if ms < 0 then 0 else ms)); _ -> pure ()
  pure VNoval)

-- ----- transport-shaped response -----

makeResponse :: Int -> Value -> [(String, Value)] -> IO Value
makeResponse status dat headers = do
  lower <- emptyMap
  mapM_ (\(k, v) -> setp lower (lower' k) v) headers
  jo [ ("status", vint status)
     , ("statusText", VStr (if status < 400 then "OK" else "ERR"))
     , ("body", VStr "not-used"), ("json", jsonThunk dat), ("headers", lower) ]
  where lower' = map toLowerC
        toLowerC ch = if ch >= 'A' && ch <= 'Z' then toEnum (fromEnum ch + 32) else ch

type Server = Fetcher

defaultServer :: Server
defaultServer = \_ _ fetchdef -> do
  m <- getp fetchdef "method"
  let meth = case m of VStr s -> upper s; _ -> "GET"
  if meth == "GET"
    then do d <- jo [("ok", VBool True), ("method", VStr meth)]; r <- makeResponse 200 d []; pure (r, Nothing)
    else do b <- getp fetchdef "body"; d <- jo [("ok", VBool True), ("method", VStr meth), ("echo", b)]; r <- makeResponse 200 d []; pure (r, Nothing)

-- A recorder: records every call; optional reply (callNo, fetchdef) -> (resp, err).
recordingServer :: Maybe (Int -> Value -> IO (Value, Maybe Value)) -> IO (Server, IORef [Value])
recordingServer mreply = do
  callsRef <- newIORef []
  let srv _ url fetchdef = do
        rec0 <- jo [("url", VStr url), ("fetchdef", fetchdef)]
        modifyIORef callsRef (++ [rec0])
        cs <- readIORef callsRef
        let n = length cs
        case mreply of
          Just r -> r n fetchdef
          Nothing -> do d <- jo [("ok", VBool True), ("n", vint n)]; resp <- makeResponse 200 d []; pure (resp, Nothing)
  pure (srv, callsRef)

-- ----- feature presence -----

-- A feature is present when the generated feature factory dispatches the
-- name to a real implementation. In this SDK every feature is always
-- compiled in (Cfg.makeFeature maps each known name to its own factory and
-- falls back to the "base" feature for unknown names), so presence is
-- determined by the factory, not by the model's default-active `feature`
-- map (which for a minimal API may list only `test`).
hasFeature :: String -> IO Bool
hasFeature name = do
  ftr <- Cfg.makeFeature name
  pure (fName ftr == name)

-- ----- harness -----

data Harness = Harness
  { hBase    :: String
  , hHeaders :: Value
  , hClient  :: Client
  , hUtility :: Utility
  , hRootctx :: Context
  }

data OpResult = OpResult
  { orOk     :: Bool
  , orData   :: Value
  , orResult :: Value
  , orCtx    :: Context
  , orErr    :: Maybe Value
  }

makeClientH :: [(String, Value)] -> Maybe Server -> [(String, Value)] -> IO Harness
makeClientH features mServer headers = do
  hheaders <- emptyMap
  mapM_ (\(k, v) -> setp hheaders k v) headers
  let srv = maybe defaultServer id mServer
  utility <- newUtility
  writeIORef (uFetcher utility) srv
  writeIORef (uParam utility) paramFn
  modeR <- newIORef "test"; featsR <- newIORef []; rootR <- newIORef Nothing; trackR <- newIORef =<< emptyMap
  hh <- clone hheaders
  fm0 <- emptyMap
  optsMap <- jo [("base", VStr "http://api.test"), ("headers", hh), ("feature", fm0)]
  optsR <- newIORef optsMap
  cfg <- Cfg.makeConfig
  let client = Client { clMode = modeR, clFeatures = featsR, clOptions = optsR, clUtility = utility
                      , clRootctx = rootR, clTrack = trackR, clConfig = cfg, clMakeFeature = Cfg.makeFeature }
  rootctx <- makeContextImpl (defaultCtxSpec { csClient = Just client, csUtility = Just utility }) Nothing
  rootOp <- newOperation =<< jo [("name", VStr "root"), ("entity", VStr "_")]
  writeIORef (cOp rootctx) rootOp
  writeIORef rootR (Just rootctx)
  mapM_ (addFeature client rootctx) features
  featureHookUtil rootctx "PostConstruct"
  pure Harness { hBase = "http://api.test", hHeaders = hheaders, hClient = client, hUtility = utility, hRootctx = rootctx }
  where
    paramFn ctx name = do
      let key = case name of VStr s -> s; _ -> ""
      specV <- readIORef (cSpec ctx)
      case specV of
        VMap _ -> do
          params <- getp specV "params"; v <- getp params key
          if not (isNoval v) then pure v else do query <- getp specV "query"; getp query key
        _ -> pure VNoval
    addFeature client rootctx (name, opts) = do
      present <- hasFeature name
      if not present then pure ()
      else do
        ftr <- Cfg.makeFeature name
        fopts <- jo [("active", VBool True)]
        case opts of VMap _ -> do { ks <- keysof opts; mapM_ (\k -> do { v <- getp opts k; setp fopts k v }) ks }; _ -> pure ()
        optsV <- readIORef (clOptions client)
        featm <- getp optsV "feature"
        case featm of VMap _ -> setp featm name fopts; _ -> pure ()
        fInit ftr rootctx fopts
        modifyIORef (clFeatures client) (++ [ftr])

harnessFeature :: Harness -> String -> IO (Maybe Feature)
harnessFeature h name = do fs <- readIORef (clFeatures (hClient h)); pure (findF fs)
  where findF [] = Nothing
        findF (f : rest) = if fName f == name then Just f else findF rest

data OpArgs = OpArgs
  { oaOp      :: String
  , oaEntity  :: String
  , oaMethod  :: Maybe String
  , oaPath    :: Maybe String
  , oaQuery   :: Maybe Value
  , oaHeaders :: [(String, Value)]
  , oaBody    :: Value
  , oaCtrl    :: Value
  }

defaultOpArgs :: OpArgs
defaultOpArgs = OpArgs "load" "widget" Nothing Nothing Nothing [] VNoval VNoval

defaultMethodH :: String -> String
defaultMethodH op = case op of "create" -> "POST"; "update" -> "PATCH"; "remove" -> "DELETE"; _ -> "GET"

buildUrl :: Value -> IO String
buildUrl spec = do
  base <- getStrD spec "base" ""
  path <- getStrD spec "path" ""
  qv <- getp spec "query"
  q <- case qv of VMap _ -> pure qv; _ -> emptyMap
  ks0 <- keysof q
  present <- filterM' (\k -> do v <- getp q k; pure (not (isNoval v))) ks0
  let keys = sort present
  parts <- mapM (\k -> do v <- getp q k; ek <- escurlS k; ev <- escurlS (vstring v); pure (ek ++ "=" ++ ev)) keys
  let qs = intercalate' "&" parts
  pure (base ++ path ++ (if null qs then "" else "?" ++ qs))

filterM' :: (a -> IO Bool) -> [a] -> IO [a]
filterM' _ [] = pure []
filterM' p (x : xs) = do b <- p x; rest <- filterM' p xs; pure (if b then x : rest else rest)

populateResultH :: Context -> Value -> Maybe Value -> IO ()
populateResultH ctx response fetchErr = do
  result <- newResult =<< emptyMap
  writeIORef (cResult ctx) result
  case fetchErr of
    Just e -> setp result "err" e
    Nothing ->
      if isNoval response || isNullV response
        then do e <- mkErr "request_no_response" "response: undefined"; setp result "err" e
        else case response of
          VMap _ -> do
            st <- getp response "status"; setp result "status" st
            stt <- getStrD response "statusText" ""; setp result "statusText" (VStr stt)
            h <- getp response "headers"; hc <- case h of { VMap _ -> clone h; _ -> emptyMap }; setp result "headers" hc
            jsn <- getp response "json"
            case jsn of VFunc _ -> do { d <- callJson jsn; setp result "body" d }; _ -> pure ()
            body <- getp result "body"; setp result "resdata" body
            let status = toInt st
            if status >= 400
              then do e <- mkErr "request_status" ("request: " ++ show status ++ ": " ++ stt); setp result "err" e
              else pure ()
            errv <- getp result "err"; isE <- isErr errv
            if not isE then setp result "ok" (VBool True) else pure ()
          _ -> do e <- mkErr "op_failed" "invalid response"; setp result "err" e

runOpH :: Harness -> OpArgs -> IO OpResult
runOpH h oa = do
  let opname = oaOp oa
      entity = oaEntity oa
      meth = maybe (defaultMethodH opname) id (oaMethod oa)
  ctrlM <- case oaCtrl oa of VMap _ -> pure (oaCtrl oa); _ -> emptyMap
  ctx <- makeContextImpl (defaultCtxSpec { csClient = Just (hClient h), csUtility = Just (hUtility h), csCtrl = Just ctrlM }) (Just (hRootctx h))
  op <- newOperation =<< jo [("name", VStr opname), ("entity", VStr entity)]
  writeIORef (cOp ctx) op
  let fh n = featureHookUtil ctx n
      finishErr err = do
        ctrl <- readIORef (cCtrl ctx); setp ctrl "err" err
        fh "PreUnexpected"
        rv <- readIORef (cResult ctx)
        pure OpResult { orOk = False, orResult = rv, orCtx = ctx, orData = VNoval, orErr = Just err }
  fh "PostConstructEntity"
  fh "PrePoint"
  out <- readIORef (cOut ctx)
  prePoint <- getp out "point"; isPE <- isErr prePoint
  if isPE then finishErr prePoint
  else do
    fh "PreSpec"
    preSpec <- getp out "spec"
    spec <- case preSpec of
      VMap _ -> pure preSpec
      _ -> do
        merged <- clone (hHeaders h); mm <- case merged of VMap _ -> pure merged; _ -> emptyMap
        mapM_ (\(k, v) -> setp mm k v) (oaHeaders oa)
        q <- case oaQuery oa of Just qq -> pure qq; Nothing -> emptyMap
        pm <- emptyMap
        newSpec =<< jo [ ("method", VStr meth), ("base", VStr (hBase h))
                       , ("path", VStr (maybe ("/" ++ entity) id (oaPath oa)))
                       , ("params", pm), ("headers", mm), ("query", q)
                       , ("body", oaBody oa), ("step", VStr "start") ]
    writeIORef (cSpec ctx) spec
    fh "PreRequest"
    url <- buildUrl spec; setp spec "url" (VStr url)
    preReq <- getp out "request"
    (response, fetchErr) <- case preReq of
      VMap _ -> pure (preReq, Nothing)
      _ -> do
        method0 <- getp spec "method"; headers0 <- getp spec "headers"; body0 <- getp spec "body"
        fetchdef <- jo [("url", VStr url), ("method", method0), ("headers", headers0), ("body", body0)]
        fetcher <- readIORef (uFetcher (hUtility h))
        fetcher ctx url fetchdef
    writeIORef (cResponse ctx) (case response of VMap _ -> response; _ -> VNoval)
    fh "PreResponse"
    populateResultH ctx response fetchErr
    fh "PreResult"
    fh "PreDone"
    rv <- readIORef (cResult ctx)
    ok <- case rv of VMap _ -> isTrueV <$> getp rv "ok"; _ -> pure False
    if ok
      then do rd <- getp rv "resdata"; pure OpResult { orOk = True, orData = rd, orResult = rv, orCtx = ctx, orErr = Nothing }
      else do
        errv <- case rv of VMap _ -> getp rv "err"; _ -> pure VNoval
        isE <- isErr errv
        e <- if isE then pure errv else mkErr "op_failed" "operation failed"
        finishErr e

