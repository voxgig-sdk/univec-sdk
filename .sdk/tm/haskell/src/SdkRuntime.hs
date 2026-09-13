-- Univec SDK runtime: the operation pipeline.
--
-- The context builder, all the `*Util` pipeline utilities (the dynamic donors'
-- utility/ layer), the utility bundle constructor, make_options and the
-- innermost transport (fetcher). Utilities are top-level IO functions that call
-- each other directly; the two members that vary per client — the transport
-- (`uFetcher`, wrapped by features) and `uParam` — are IORef cells so features
-- and tests can rebind them. Everything runs in IO because struct nodes are
-- IORef-backed and reference-stable.

module SdkRuntime where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Data.Bits ((.&.))
import Data.Char (isAlphaNum, toUpper)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import System.IO.Unsafe (unsafePerformIO)
import Text.Printf (printf)

import VoxgigStruct
  ( Value (..), InjArg (..), emptyList, emptyMap, mkList, mkMap
  , getprop, getpropAlt, setprop, delprop, getpath, getelem, keysof, listItems
  , items, clone, merge, validate, transform, select, size, isempty
  , isnode, ismap, islist, isfunc, isNoval, isNullish, vint
  , escurl, escre, stringify, walk, join )
import SdkTypes
import SdkHelpers

-- ------------------------------------------------------------------
-- random ids (no external dep; LCG)
-- ------------------------------------------------------------------

{-# NOINLINE randSeed #-}
randSeed :: IORef Int
randSeed = unsafePerformIO (newIORef 123456789)

randInt :: Int -> IO Int
randInt n
  | n <= 0 = pure 0
  | otherwise = do
      s <- readIORef randSeed
      let s' = (s * 1103515245 + 12345) .&. 0x7fffffff
      writeIORef randSeed s'
      pure (s' `mod` n)

randHex4 :: IO String
randHex4 = printf "%04x" <$> randInt 0x10000

randId16 :: IO String
randId16 = concat <$> sequence [randHex4, randHex4, randHex4, randHex4]

nextCtxId :: IO String
nextCtxId = do n <- randInt 90000000; pure ("C" ++ show (10000000 + n))

escurlS :: String -> IO String
escurlS s = do r <- escurl (VStr s); pure (case r of VStr x -> x; _ -> s)

escreS :: String -> IO String
escreS s = do r <- escre (VStr s); pure (case r of VStr x -> x; _ -> s)

valEqScalar :: Value -> Value -> Bool
valEqScalar a b = case (a, b) of
  (VNoval, VNoval) -> True
  (VNull, VNull) -> True
  (VNoval, VNull) -> True
  (VNull, VNoval) -> True
  (VStr x, VStr y) -> x == y
  (VNum x, VNum y) -> x == y
  (VBool x, VBool y) -> x == y
  _ -> False

-- ------------------------------------------------------------------
-- context builder
-- ------------------------------------------------------------------

clientOptionsMap :: Client -> IO Value
clientOptionsMap cl = do
  o <- readIORef (clOptions cl)
  c <- clone o
  case c of VMap _ -> pure c; _ -> emptyMap

resolveOp :: Context -> String -> IO Operation
resolveOp ctx opname = do
  ment <- readIORef (cEntity ctx)
  let entname = maybe "_" eName ment
      cacheKey = opCacheKey entname opname
  m <- readIORef (cOpmap ctx)
  case Map.lookup cacheKey m of
    Just op -> pure op
    Nothing ->
      if opname == ""
        then newOperation =<< emptyMap
        else do
          cfg <- readIORef (cConfig ctx)
          opcfg <- getpathS cfg ("entity." ++ entname ++ ".op." ++ opname)
          let inpt = if opname == "update" || opname == "create" then "data" else "match"
          pts <- case opcfg of
            VMap _ -> do p <- getp opcfg "points"; case p of VList _ -> pure p; _ -> emptyList
            _ -> emptyList
          opm <- jo [("entity", VStr entname), ("name", VStr opname), ("input", VStr inpt), ("points", pts)]
          op <- newOperation opm
          modifyIORef' (cOpmap ctx) (Map.insert cacheKey op)
          pure op

makeContextImpl :: CtxSpec -> Maybe Context -> IO Context
makeContextImpl cs basectx = do
  cid <- nextCtxId

  client <- case csClient cs of
    Just c -> pure (Just c)
    Nothing -> maybe (pure Nothing) (readIORef . cClient) basectx

  utility <- case csUtility cs of
    Just u -> pure (Just u)
    Nothing -> maybe (pure Nothing) (readIORef . cUtility) basectx

  ctrl <- case csCtrl cs of
    Just cr@(VMap _) -> do
      c <- newControl
      thr <- getp cr "throw_err"
      case thr of
        VBool b -> setp c "throw" (VBool b)
        _ -> do t2 <- getp cr "throw"; case t2 of VBool b -> setp c "throw" (VBool b); _ -> pure ()
      ex <- getp cr "explain"; case ex of VMap _ -> setp c "explain" ex; _ -> pure ()
      ac <- getp cr "actor"; case ac of VNoval -> pure (); _ -> setp c "actor" ac
      pg <- getp cr "paging"; case pg of VMap _ -> setp c "paging" pg; _ -> pure ()
      pure c
    _ -> maybe newControl (readIORef . cCtrl) basectx

  meta <- case csMeta cs of
    Just m@(VMap _) -> pure m
    _ -> case basectx of
      Just b -> do mv <- readIORef (cMeta b); case mv of VMap _ -> pure mv; _ -> emptyMap
      Nothing -> emptyMap

  config <- inheritMap (csConfig cs) (cConfig <$> basectx) VNoval
  entopts <- inheritMap (csEntopts cs) (cEntopts <$> basectx) VNoval
  options <- inheritMap (csOptions cs) (cOptions <$> basectx) VNoval

  entity <- case csEntity cs of
    Just e -> pure (Just e)
    Nothing -> maybe (pure Nothing) (readIORef . cEntity) basectx

  shared <- case csShared cs of
    Just m@(VMap _) -> pure m
    _ -> maybe (pure VNoval) (readIORef . cShared) basectx

  opmapRef <- case csOpmap cs of
    Just r -> pure r
    Nothing -> case basectx of Just b -> pure (cOpmap b); Nothing -> newIORef Map.empty

  dat <- mapOf (csData cs)
  reqdata <- mapOf (csReqdata cs)
  mtch <- mapOf (csMatch cs)
  reqmatch <- mapOf (csReqmatch cs)

  point <- case csPoint cs of
    Just m@(VMap _) -> pure m
    _ -> maybe (pure VNoval) (readIORef . cPoint) basectx

  spec <- inheritObj (csSpec cs) (cSpec <$> basectx)
  result <- inheritObj (csResult cs) (cResult <$> basectx)
  response <- inheritObj (csResponse cs) (cResponse <$> basectx)

  op0 <- newOperation =<< emptyMap
  scratch <- emptyMap
  out <- emptyMap

  cOutR <- newIORef out
  cCtrlR <- newIORef ctrl
  cMetaR <- newIORef meta
  cClientR <- newIORef client
  cUtilR <- newIORef utility
  cOpR <- newIORef op0
  cPointR <- newIORef point
  cConfigR <- newIORef config
  cEntoptsR <- newIORef entopts
  cOptionsR <- newIORef options
  cResponseR <- newIORef response
  cResultR <- newIORef result
  cSpecR <- newIORef spec
  cDataR <- newIORef dat
  cReqdataR <- newIORef reqdata
  cMatchR <- newIORef mtch
  cReqmatchR <- newIORef reqmatch
  cEntityR <- newIORef entity
  cSharedR <- newIORef shared
  cScratchR <- newIORef scratch

  let ctx = Context
        { cId = cid, cOut = cOutR, cCtrl = cCtrlR, cMeta = cMetaR
        , cClient = cClientR, cUtility = cUtilR, cOp = cOpR, cPoint = cPointR
        , cConfig = cConfigR, cEntopts = cEntoptsR, cOptions = cOptionsR
        , cOpmap = opmapRef, cResponse = cResponseR, cResult = cResultR
        , cSpec = cSpecR, cData = cDataR, cReqdata = cReqdataR, cMatch = cMatchR
        , cReqmatch = cReqmatchR, cEntity = cEntityR, cShared = cSharedR
        , cScratch = cScratchR }

  let opname = maybe "" id (csOpname cs)
  op <- resolveOp ctx opname
  writeIORef cOpR op
  pure ctx
  where
    inheritMap mcs mbfield dflt = case mcs of
      Just m@(VMap _) -> pure m
      _ -> case mbfield of Just r -> readIORef r; Nothing -> pure dflt
    inheritObj mcs mbfield = case mcs of
      Just v -> pure v
      _ -> case mbfield of Just r -> readIORef r; Nothing -> pure VNoval
    mapOf mv = case mv of
      Just d -> case toMap d of VMap _ -> pure d; _ -> emptyMap
      Nothing -> emptyMap

-- ------------------------------------------------------------------
-- utilities
-- ------------------------------------------------------------------

cleanUtil :: Context -> Value -> IO Value
cleanUtil _ v = pure v

makeErrorUtil :: Context -> Maybe Value -> IO Value
makeErrorUtil ctx merr = do
  op <- readIORef (cOp ctx)
  let opname0 = opName op
      opname = if opname0 == "" || opname0 == "_" then "unknown operation" else opname0
  resultV <- readIORef (cResult ctx)
  result <- case resultV of VMap _ -> pure resultV; _ -> newResult =<< emptyMap
  setp result "ok" (VBool False)
  err <- case merr of
    Just e -> pure e
    Nothing -> do
      re <- getp result "err"; isE <- isErr re
      if isE then pure re else mkErr "unknown" "unknown error"
  em <- errMsg err
  let msg = "UnivecSDK: " ++ opname ++ ": " ++ em
  setp result "err" VNoval
  ctrl <- readIORef (cCtrl ctx)
  explain <- getp ctrl "explain"
  case explain of
    VMap _ -> do e2 <- jo [("message", VStr msg)]; setp explain "err" e2
    _ -> pure ()
  ecode <- errCode err
  rv <- resultToValue result
  specV <- readIORef (cSpec ctx)
  sv <- case specV of VMap _ -> specToValue specV; _ -> pure VNoval
  sdkErr <- jo [ ("__sdkerr__", VBool True), ("code", VStr ecode), ("message", VStr msg)
               , ("result", rv), ("spec", sv) ]
  setp ctrl "err" sdkErr
  -- Fire PreUnexpected so observability features (metrics, telemetry, audit,
  -- debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  -- rbac short-circuit). Fires after ctrl err is set so hooks can read the
  -- error; features guard against double-recording when PreDone already fired.
  featureHookUtil ctx "PreUnexpected"
  thr <- getp ctrl "throw"
  case thr of
    VBool False -> getp result "resdata"
    _ -> throwIO (SdkException sdkErr)

doneUtil :: Context -> IO Value
doneUtil ctx = do
  ctrl <- readIORef (cCtrl ctx)
  explain <- getp ctrl "explain"
  case explain of
    VMap _ -> do
      er <- getp explain "result"
      case er of VMap _ -> delp er "err"; _ -> pure ()
    _ -> pure ()
  resultV <- readIORef (cResult ctx)
  case resultV of
    VMap _ -> do
      ok <- getp resultV "ok"
      if isTrueV ok then getp resultV "resdata" else makeErrorUtil ctx Nothing
    _ -> makeErrorUtil ctx Nothing

-- ----- feature utilities -----

featureHookUtil :: Context -> String -> IO ()
featureHookUtil ctx name = do
  mcl <- readIORef (cClient ctx)
  case mcl of
    Nothing -> pure ()
    Just cl -> do fs <- readIORef (clFeatures cl); mapM_ (\f -> fHook f name ctx) fs

featureAddUtil :: Context -> Feature -> IO ()
featureAddUtil ctx f = do
  cl <- cc ctx
  fopts <- readIORef (fOptions f)
  let posOpt k = do
        v <- case fopts of VMap _ -> getp fopts k; _ -> pure VNoval
        pure (case v of VStr s -> Just s; _ -> Nothing)
  before <- posOpt "__before__"
  after <- posOpt "__after__"
  replace <- posOpt "__replace__"
  feats <- readIORef (clFeatures cl)
  let hasPos = before /= Nothing || after /= Nothing || replace /= Nothing
      go _ [] = Nothing
      go acc (ef : rest)
        | before == Just (fName ef) = Just (reverse acc ++ (f : ef : rest))
        | after == Just (fName ef) = Just (reverse acc ++ (ef : f : rest))
        | replace == Just (fName ef) = Just (reverse acc ++ (f : rest))
        | otherwise = go (ef : acc) rest
      positioned = if hasPos then go [] feats else Nothing
  case positioned of
    Just l -> writeIORef (clFeatures cl) l
    Nothing -> writeIORef (clFeatures cl) (feats ++ [f])

featureInitUtil :: Context -> Feature -> IO ()
featureInitUtil ctx f = do
  let fname = fName f
  opts <- readIORef (cOptions ctx)
  fo <- getp opts "feature"
  fopts <- case fo of
    VMap _ -> do foo <- getp fo fname; case foo of VMap _ -> pure foo; _ -> emptyMap
    _ -> emptyMap
  active <- getp fopts "active"
  when (isTrueV active) (fInit f ctx fopts)

-- ----- prepare / param -----

-- The API definition is authoritative: a POST-only or PATCH-based API
-- exposes `update` as POST or PATCH, not the PUT the op name implies. Only
-- fall back to the op-name convention when the point has no method.
prepareMethodUtil :: Context -> IO String
prepareMethodUtil ctx = do
  point <- readIORef (cPoint ctx)
  pm <- getp point "method"
  case pm of
    VStr m | not (null m) -> pure (map toUpper m)
    _ -> do
      op <- readIORef (cOp ctx)
      pure $ case opName op of
        "create" -> "POST"; "update" -> "PUT"; "load" -> "GET"
        "list" -> "GET"; "remove" -> "DELETE"; "patch" -> "PATCH"
        -- NO CATCH-ALL GET. The ts reference returns methodMap[key], which is
        -- undefined for an op the map does not name — the request is then
        -- rejected rather than silently issued. A `_ -> "GET"` here turned
        -- every unrecognised op into a GET, which is both a divergence from
        -- the corpus (which expects no method for opname "bad") and the more
        -- dangerous of the two behaviours: a mistyped or unsupported op
        -- quietly fetched. Found by the primary corpus on its first run.
        _ -> ""

prepareHeadersUtil :: Context -> IO Value
prepareHeadersUtil ctx = do
  cl <- cc ctx
  options <- clientOptionsMap cl
  h <- getp options "headers"
  case h of
    VNoval -> emptyMap
    _ -> do c <- clone h; case c of VMap _ -> pure c; _ -> emptyMap

paramUtil :: Context -> Value -> IO Value
paramUtil ctx paramdef = do
  point <- readIORef (cPoint ctx)
  specV <- readIORef (cSpec ctx)
  mtch <- readIORef (cMatch ctx)
  reqmatch <- readIORef (cReqmatch ctx)
  dat <- readIORef (cData ctx)
  reqdata <- readIORef (cReqdata ctx)
  key <- case paramdef of VStr s -> pure s; _ -> getStrD paramdef "name" ""
  aliasV <- getp point "alias"
  akey <- case aliasV of VMap _ -> getStrD aliasV key ""; _ -> pure ""
  let orElse v act = if isNoval v then act else pure v
  v1 <- getp reqmatch key
  v2 <- orElse v1 (getp mtch key)
  v3 <- if isNoval v2 && not (null akey)
          then do
            case specV of
              VMap _ -> do sa <- getp specV "alias"; setp sa akey (VStr key)
              _ -> pure ()
            getp reqmatch akey
          else pure v2
  v4 <- orElse v3 (getp reqdata key)
  v5 <- orElse v4 (getp dat key)
  if isNoval v5 && not (null akey)
    then do a <- getp reqdata akey; orElse a (getp dat akey)
    else pure v5

prepareParamsUtil :: Context -> IO Value
prepareParamsUtil ctx = do
  point <- readIORef (cPoint ctx)
  args <- getp point "args"
  params <- case args of
    VMap _ -> do p <- getp args "params"; case p of VList _ -> listItems p; _ -> pure []
    _ -> pure []
  out <- emptyMap
  u <- cu ctx
  pfn <- readIORef (uParam u)
  forM_ params $ \pd -> do
    v <- pfn ctx pd
    when (not (isNoval v)) $
      case pd of
        VMap _ -> do nm <- getStrD pd "name" ""; when (nm /= "") (setp out nm v)
        _ -> pure ()
  pure out

preparePathUtil :: Context -> IO String
preparePathUtil ctx = do
  point <- readIORef (cPoint ctx)
  p <- getp point "parts"
  parts <- case p of VList _ -> pure p; _ -> emptyList
  join_ parts

prepareQueryUtil :: Context -> IO Value
prepareQueryUtil ctx = do
  point <- readIORef (cPoint ctx)
  rmV <- readIORef (cReqmatch ctx)
  reqmatch <- case rmV of VMap _ -> pure rmV; _ -> emptyMap
  pl <- getp point "params"
  params <- case pl of VList _ -> listItems pl; _ -> pure []
  let containsParam s = any (\v -> case v of VStr x -> x == s; _ -> False) params
  out <- emptyMap
  ks <- keysof reqmatch
  forM_ ks $ \k -> do
    v <- getp reqmatch k
    when (not (isNoval v) && not (containsParam k)) (setp out k v)
  pure out

prepareBodyUtil :: Context -> IO Value
prepareBodyUtil ctx = do
  op <- readIORef (cOp ctx)
  if opInput op == "data" then transformRequestUtil ctx else pure VNoval

-- ------------------------------------------------------------------
-- graphql (transport)
--
-- GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
-- produces uses this code unchanged. The API-specific part — which
-- operations exist and what each one's document is — is model data, computed
-- once by apidef and emitted into Config.
--
-- Two jobs:
--
--   graphqlBodyUtil   — build { query, variables } for a point, binding the
--                       op's arguments to the document's declared variables.
--
--   graphqlErrorsUtil — lift a GraphQL failure into an SDK error. GraphQL
--                       reports failures as a top-level `errors` array under
--                       HTTP 200, so the status-driven path in resultBasic
--                       never sees them.
-- ------------------------------------------------------------------

-- Content type every GraphQL-over-HTTP request uses.
graphqlContentType :: String
graphqlContentType = "application/json"

-- Map a GraphQL error to the same error codes the HTTP path produces, so a
-- caller handles auth or rate limiting identically on both transports.
-- Servers put the machine-readable code in `extensions.code`; Linear-style
-- APIs use `extensions.type`.
graphqlErrorCode :: Value -> IO String
graphqlErrorCode gqlerr = do
  ext <- getp gqlerr "extensions"
  c0 <- getStrD ext "code" ""
  code <- if null c0 then getStrD ext "type" "" else pure c0
  let raw = map toUpper code
  pure $
    if substrContains raw "AUTH" || substrContains raw "FORBIDDEN"
         || substrContains raw "UNAUTHENTICATED"
      then "request_auth"
      else if substrContains raw "RATELIMIT" || substrContains raw "RATE_LIMIT"
                || substrContains raw "TOO_MANY"
        then "request_ratelimit"
        else if substrContains raw "BAD_USER_INPUT"
                  || substrContains raw "VALIDATION"
                  || substrContains raw "INVALID"
          then "request_invalid"
          else "request_graphql"

-- Build the request body for a GraphQL point.
--
-- Variables come from the op's own arguments: a named variable binds to the
-- like-named argument (`from`), and the input-object variable (empty `from`)
-- takes the request data as a whole — which is what makes a generated
-- create/update call look exactly like its REST equivalent.
graphqlBodyUtil :: Context -> IO Value
graphqlBodyUtil ctx = do
  point <- readIORef (cPoint ctx)
  gql <- getp point "graphql"
  case gql of
    VMap _ -> do
      -- reqmatch/reqdata hold the caller's arguments for THIS call;
      -- data/match hold the entity's current state. Which pair depends on
      -- whether the op takes match or data input. A named variable falls
      -- back to the current state, so updating a loaded entity with just
      -- {title} still binds the stored id the mutation requires.
      op <- readIORef (cOp ctx)
      let datainput = opInput op == "data"
      rsV <- readIORef (if datainput then cReqdata ctx else cReqmatch ctx)
      dsV <- readIORef (if datainput then cData ctx else cMatch ctx)
      reqsrc <- case rsV of VMap _ -> pure rsV; _ -> emptyMap
      datasrc <- case dsV of VMap _ -> pure dsV; _ -> emptyMap
      variables <- emptyMap
      vl <- getp gql "vars"
      varlist <- case vl of VList _ -> listItems vl; _ -> pure []
      forM_ varlist $ \spec -> case spec of
        VMap _ -> do
          name <- getStrD spec "name" ""
          from <- getStrD spec "from" ""
          when (not (null name)) $
            if null from
              then do
                -- The input object IS the request body. Strip the action
                -- selector, which is an SDK-side point discriminator, not an
                -- API field.
                body <- emptyMap
                ks <- keysof reqsrc
                forM_ ks $ \k -> when (k /= "$action") $ do
                  v <- getp reqsrc k
                  setp body k v
                setp variables name body
              else do
                -- Only send variables the caller actually supplied: sending
                -- an explicit null would clear a field on many APIs.
                v0 <- getp reqsrc from
                val <- if isNullish v0 then getp datasrc from else pure v0
                when (not (isNullish val)) (setp variables name val)
        _ -> pure ()
      doc <- getp gql "doc"
      jo [("query", doc), ("variables", variables)]
    _ -> pure VNoval

-- Inspect a decoded GraphQL response body and record a failure when the
-- server reported one. Returns True when an error was recorded.
--
-- Partial data (`data` alongside `errors`) is treated as failure: the REST
-- surface has no partial-success concept, and silently returning half an
-- object would be worse than failing.
graphqlErrorsUtil :: Context -> IO Bool
graphqlErrorsUtil ctx = do
  resultV <- readIORef (cResult ctx)
  point <- readIORef (cPoint ctx)
  kind <- getStrD point "kind" ""
  case resultV of
    VMap _ | kind == "graphql" -> do
      body <- getp resultV "body"
      ev <- getp body "errors"
      errors <- case ev of VList _ -> listItems ev; _ -> pure []
      if null errors
        then pure False
        else do
          let firsterr = head errors
              n = length errors
          m0 <- getStrD firsterr "message" ""
          let m1 = if null m0 then "graphql error" else m0
              msg = if 1 < n then m1 ++ " (+" ++ show (n - 1) ++ " more)" else m1
          code <- graphqlErrorCode firsterr
          e <- mkErr code ("graphql: " ++ msg)
          setp resultV "err" e
          setp resultV "ok" (VBool False)
          pure True
    _ -> pure False

prepareAuthUtil :: Context -> UResult
prepareAuthUtil ctx = do
  specV <- readIORef (cSpec ctx)
  case specV of
    VMap _ -> do
      headers <- getp specV "headers"
      cl <- cc ctx
      options <- clientOptionsMap cl
      authv <- getp options "auth"
      case authv of
        VNoval -> do delp headers "authorization"; pure (specV, Nothing)
        VNull -> do delp headers "authorization"; pure (specV, Nothing)
        _ -> do
          apikey <- getpropAlt (VStr "__NOTFOUND__") options (VStr "apikey")
          let isNotFound = case apikey of VStr "__NOTFOUND__" -> True; _ -> False
              apikeyStr = case apikey of VStr s -> s; _ -> ""
          if isNotFound || isNoval apikey || apikeyStr == ""
            then do delp headers "authorization"; pure (specV, Nothing)
            else do
              apV <- getpathS options "auth.prefix"
              let authPrefix = case apV of VStr s -> s; _ -> ""
                  authval = if authPrefix /= "" then authPrefix ++ " " ++ apikeyStr else apikeyStr
              setp headers "authorization" (VStr authval)
              pure (specV, Nothing)
    _ -> do e <- mkErr "auth_no_spec" "Expected context spec property to be defined."; pure (VNoval, Just e)

-- ----- transforms / result helpers -----

transformRequestUtil :: Context -> IO Value
transformRequestUtil ctx = do
  specV <- readIORef (cSpec ctx)
  case specV of VMap _ -> setp specV "step" (VStr "reqform"); _ -> pure ()
  point <- readIORef (cPoint ctx)
  reqdata <- readIORef (cReqdata ctx)
  tr <- toMap <$> getp point "transform"
  case tr of
    VMap _ -> do
      reqform <- getp tr "req"
      case reqform of
        VNoval -> pure reqdata
        _ -> do input <- jo [("reqdata", reqdata)]; transform INone input reqform
    _ -> pure reqdata

transformResponseUtil :: Context -> IO Value
transformResponseUtil ctx = do
  specV <- readIORef (cSpec ctx)
  case specV of VMap _ -> setp specV "step" (VStr "resform"); _ -> pure ()
  resultV <- readIORef (cResult ctx)
  case resultV of
    VMap _ -> do
      ok <- getp resultV "ok"
      if not (isTrueV ok) then pure VNoval
      else do
        point <- readIORef (cPoint ctx)
        tr <- toMap <$> getp point "transform"
        case tr of
          VMap _ -> do
            resform <- getp tr "res"
            case resform of
              VNoval -> pure VNoval
              _ -> do
                status <- getp resultV "status"
                st <- getp resultV "statusText"
                hdr <- getp resultV "headers"
                body <- getp resultV "body"
                errv <- getp resultV "err"
                isE <- isErr errv
                errOut <- if isE then do m <- getp errv "message"; jo [("message", m)] else pure VNoval
                resdata <- getp resultV "resdata"
                resmatch <- getp resultV "resmatch"
                input <- jo [ ("ok", ok), ("status", status), ("statusText", st)
                            , ("headers", hdr), ("body", body), ("err", errOut)
                            , ("resdata", resdata), ("resmatch", resmatch) ]
                rd <- transform INone input resform
                setp resultV "resdata" rd
                pure rd
          _ -> pure VNoval
    _ -> pure VNoval

resultBasicUtil :: Context -> IO ()
resultBasicUtil ctx = do
  responseV <- readIORef (cResponse ctx)
  resultV <- readIORef (cResult ctx)
  case (responseV, resultV) of
    (VMap _, VMap _) -> do
      st <- getp responseV "status"
      stt <- getp responseV "statusText"
      setp resultV "status" st
      setp resultV "statusText" stt
      let status = toInt st
          sttext = case stt of VStr s -> s; _ -> ""
      if status >= 400
        then do
          let msg = "request: " ++ show status ++ ": " ++ sttext
          prev <- getp resultV "err"
          isE <- isErr prev
          if isE
            then do pm <- errMsg prev; e <- mkErr "request_status" (pm ++ ": " ++ msg); setp resultV "err" e
            else do e <- mkErr "request_status" msg; setp resultV "err" e
        else do
          re <- getp responseV "err"
          isE <- isErr re
          when isE (setp resultV "err" re)
    _ -> pure ()

resultBodyUtil :: Context -> IO ()
resultBodyUtil ctx = do
  responseV <- readIORef (cResponse ctx)
  resultV <- readIORef (cResult ctx)
  case (responseV, resultV) of
    (VMap _, VMap _) -> do
      jsn <- getp responseV "json"
      body <- getp responseV "body"
      when (isCallable jsn && not (isNoval body)) $ do
        d <- callJson jsn
        setp resultV "body" d
    _ -> pure ()

resultHeadersUtil :: Context -> IO ()
resultHeadersUtil ctx = do
  resultV <- readIORef (cResult ctx)
  case resultV of
    VMap _ -> do
      responseV <- readIORef (cResponse ctx)
      case responseV of
        VMap _ -> do
          h <- getp responseV "headers"
          case h of VMap _ -> setp resultV "headers" h; _ -> do em <- emptyMap; setp resultV "headers" em
        _ -> do em <- emptyMap; setp resultV "headers" em
    _ -> pure ()

-- ----- make_* pipeline stages -----

makePointUtil :: Context -> UResult
makePointUtil ctx = do
  out <- readIORef (cOut ctx)
  pre <- getp out "point"
  isE <- isErr pre
  if isE then pure (VNoval, Just pre)
  else case pre of
    VMap _ -> do writeIORef (cPoint ctx) pre; pure (pre, Nothing)
    _ -> do
      op <- readIORef (cOp ctx)
      options <- readIORef (cOptions ctx)
      av <- getpathS options "allow.op"
      let allowOp = case av of VStr s -> s; _ -> ""
      if not (substrContains allowOp (opName op))
        then do
          e <- mkErr "point_op_allow"
                 ("Operation \"" ++ opName op ++ "\" not allowed by SDK option allow.op value: \"" ++ allowOp ++ "\"")
          pure (VNoval, Just e)
        else do
          pts <- listItems (opPoints op)
          case pts of
            [] -> do e <- mkErr "point_no_points" ("Operation \"" ++ opName op ++ "\" has no endpoint definitions."); pure (VNoval, Just e)
            [single] -> do writeIORef (cPoint ctx) single; pure (single, Nothing)
            _ -> do
              (reqsel, sel) <- if opInput op == "data"
                then (,) <$> readIORef (cReqdata ctx) <*> readIORef (cData ctx)
                else (,) <$> readIORef (cReqmatch ctx) <*> readIORef (cMatch ctx)
              let isFound pt = do
                    selectDef <- toMap <$> getp pt "select"
                    existOk <- case selectDef of
                      VMap _ -> do
                        exist <- getp selectDef "exist"
                        case exist of
                          VList _ -> do
                            eks <- listItems exist
                            let chk found ek = if not found then pure False else do
                                  let existkey = vstring ek
                                  rv <- getp reqsel existkey; sv <- getp sel existkey
                                  pure (not (isNoval rv && isNoval sv))
                            foldMB True chk eks
                          _ -> pure True
                      _ -> pure True
                    if not existOk then pure False
                    else do
                      reqAction <- getp reqsel "$action"
                      selectAction <- getp selectDef "$action"
                      pure (valEqScalar reqAction selectAction)
                  findMatch [] = pure Nothing
                  findMatch (pt : rest) = do
                    f <- isFound pt
                    if f then pure (Just pt) else findMatch rest
                  -- A record route ends in the record's identifier
                  -- (/boards/{id}); a cross-reference that also returns the
                  -- entity ends in the relationship's name
                  -- (/posts/{id}/author). That, then fewest segments, tells
                  -- the entity's own route from a cross-reference. The same
                  -- rule runs at generation time, in helpers/opShape.ts —
                  -- both sides must move together.
                  ptsLen pt = do
                    parts <- getp pt "parts"
                    case parts of
                      VList _ -> length <$> listItems parts
                      _ -> pure (0 :: Int)
                  terminalParam pt = do
                    parts <- getp pt "parts"
                    case parts of
                      VList _ -> do
                        items <- listItems parts
                        pure (case reverse items of
                                (lastp : _) -> case vstring lastp of
                                                 ('{' : _) -> True
                                                 _ -> False
                                [] -> False)
                      _ -> pure False
                  betterOwn cand best = do
                    ct <- terminalParam cand
                    bt <- terminalParam best
                    if ct /= bt
                      then pure ct
                      else do
                        cl <- ptsLen cand
                        bl <- ptsLen best
                        pure (cl < bl)
                  ownPoint [] = pure VNoval
                  ownPoint (p0 : rest0) = go p0 rest0
                    where go best [] = pure best
                          go best (c : cs) = do
                            b <- betterOwn c best
                            go (if b then c else best) cs
              matched <- findMatch pts
              reqAction <- getp reqsel "$action"
              chosen <- maybe (ownPoint pts) pure matched
              -- select.exist can list more than the params needed to pick a
              -- point, so nothing matched. A request naming an action gets
              -- here only because that action's own point failed its exist
              -- test, so it is unbuildable whatever we pick — refuse it
              -- BEFORE the guard below, which compares the chosen point's
              -- $action and would wave the request through whenever the
              -- fallback lands on the action point itself.
              if isNothing matched && not (isNoval reqAction)
                then do
                  e <- mkErr "point_action_invalid" ("Operation \"" ++ opName op ++ "\" action \"" ++ vstring reqAction ++ "\" is not valid.")
                  pure (VNoval, Just e)
                else if not (isNoval reqAction) && not (isNoval chosen)
                then do
                  pointSelect <- toMap <$> getp chosen "select"
                  pointAction <- getp pointSelect "$action"
                  if not (valEqScalar reqAction pointAction)
                    then do e <- mkErr "point_action_invalid" ("Operation \"" ++ opName op ++ "\" action \"" ++ vstring reqAction ++ "\" is not valid."); pure (VNoval, Just e)
                    else do writeIORef (cPoint ctx) chosen; pure (chosen, Nothing)
                else do writeIORef (cPoint ctx) chosen; pure (chosen, Nothing)

foldMB :: Bool -> (Bool -> a -> IO Bool) -> [a] -> IO Bool
foldMB acc _ [] = pure acc
foldMB acc f (x : xs) = do acc' <- f acc x; foldMB acc' f xs

makeSpecUtil :: Context -> UResult
makeSpecUtil ctx = do
  out <- readIORef (cOut ctx)
  pre <- getp out "spec"
  isE <- isErr pre
  if isE then pure (VNoval, Just pre)
  else case pre of
    VMap _ -> do writeIORef (cSpec ctx) pre; pure (pre, Nothing)
    _ -> do
      options <- readIORef (cOptions ctx)
      base <- getStrD options "base" ""
      prefix <- getStrD options "prefix" ""
      suffix <- getStrD options "suffix" ""
      point <- readIORef (cPoint ctx)
      p <- getp point "parts"
      parts <- case p of VList _ -> pure p; _ -> emptyList
      specm <- jo [("base", VStr base), ("prefix", VStr prefix), ("parts", parts), ("suffix", VStr suffix), ("step", VStr "start")]
      sp <- newSpec specm
      writeIORef (cSpec ctx) sp
      method <- prepareMethodUtil ctx
      setp sp "method" (VStr method)
      amv <- getpathS options "allow.method"
      let allowMethod = case amv of VStr s -> s; _ -> ""
      if not (substrContains allowMethod method)
        then do e <- mkErr "spec_method_allow" ("Method \"" ++ method ++ "\" not allowed by SDK option allow.method value: \"" ++ allowMethod ++ "\""); pure (VNoval, Just e)
        else do
          params <- prepareParamsUtil ctx; setp sp "params" params
          query <- prepareQueryUtil ctx; setp sp "query" query
          headers <- prepareHeadersUtil ctx; setp sp "headers" headers
          kind <- getStrD point "kind" ""
          if kind == "graphql"
            -- GraphQL addresses one endpoint: no path parts, no query string,
            -- and the body carries the operation. prepareBody is skipped
            -- deliberately — it only emits a body for data-input ops, whereas
            -- every GraphQL op posts one, including load/list/remove.
            then do
              body <- graphqlBodyUtil ctx; setp sp "body" body
              setp sp "path" (VStr "")
              -- prepareQuery already copied the op's match arguments into the
              -- query string. Those same values are bound as operation
              -- variables, so leaving them would send /graphql?id=i1.
              emptyq <- emptyMap; setp sp "query" emptyq
              setp headers "content-type" (VStr graphqlContentType)
            else do
              body <- prepareBodyUtil ctx; setp sp "body" body
              path <- preparePathUtil ctx; setp sp "path" (VStr path)
          ctrl <- readIORef (cCtrl ctx)
          explain <- getp ctrl "explain"
          case explain of { VMap _ -> do { snap <- specToValue sp; setp explain "spec" snap }; _ -> pure () }
          (sp2, merr) <- prepareAuthUtil ctx
          case merr of
            Just e -> pure (VNoval, Just e)
            Nothing -> do writeIORef (cSpec ctx) sp2; pure (sp2, Nothing)

makeUrlUtil :: Context -> UResult
makeUrlUtil ctx = do
  specV <- readIORef (cSpec ctx)
  resultV <- readIORef (cResult ctx)
  case specV of
    VMap _ -> case resultV of
      VMap _ -> do
        base <- getStrD specV "base" ""
        prefix <- getStrD specV "prefix" ""
        path <- getStrD specV "path" ""
        suffix <- getStrD specV "suffix" ""
        arr <- ja [VStr base, VStr prefix, VStr path, VStr suffix]
        url0 <- join_ arr
        resmatch <- emptyMap
        params <- getp specV "params"
        pks <- keysof params
        url1 <- foldMS url0 pks $ \u k -> do
          v <- getp params k
          if isNoval v then pure u
          else do enc <- escurlS (vstring v); setp resmatch k v; pure (strReplaceAll u ("{" ++ k ++ "}") enc)
        query <- getp specV "query"
        qks <- keysof query
        (url2, _) <- foldMS2 (url1, "?") qks $ \(u, qsep) k -> do
          v <- getp query k
          if isNoval v then pure (u, qsep)
          else do ek <- escurlS k; ev <- escurlS (vstring v); setp resmatch k v; pure (u ++ qsep ++ ek ++ "=" ++ ev, "&")
        setp resultV "resmatch" resmatch
        pure (VStr url2, Nothing)
      _ -> do e <- mkErr "url_no_result" "Expected context result property to be defined."; pure (VStr "", Just e)
    _ -> do e <- mkErr "url_no_spec" "Expected context spec property to be defined."; pure (VStr "", Just e)

foldMS :: b -> [a] -> (b -> a -> IO b) -> IO b
foldMS z xs f = go z xs where go acc [] = pure acc; go acc (y : ys) = do acc' <- f acc y; go acc' ys

foldMS2 :: (b, c) -> [a] -> ((b, c) -> a -> IO (b, c)) -> IO (b, c)
foldMS2 z xs f = go z xs where go acc [] = pure acc; go acc (y : ys) = do acc' <- f acc y; go acc' ys

makeFetchDefUtil :: Context -> UResult
makeFetchDefUtil ctx = do
  specV <- readIORef (cSpec ctx)
  case specV of
    VMap _ -> do
      resultV <- readIORef (cResult ctx)
      case resultV of VMap _ -> pure (); _ -> do r <- newResult =<< emptyMap; writeIORef (cResult ctx) r
      setp specV "step" (VStr "prepare")
      (urlV, merr) <- makeUrlUtil ctx
      case merr of
        Just e -> pure (VNoval, Just e)
        Nothing -> do
          let url = vstring urlV
          setp specV "url" (VStr url)
          method <- getStrD specV "method" "GET"
          headers <- getp specV "headers"
          fetchdef <- jo [("url", VStr url), ("method", VStr method), ("headers", headers)]
          body <- getp specV "body"
          case body of
            VNoval -> pure ()
            VMap _ -> do bs <- jsonifyCompact body; setp fetchdef "body" (VStr bs)
            _ -> setp fetchdef "body" body
          pure (fetchdef, Nothing)
    _ -> do e <- mkErr "fetchdef_no_spec" "Expected context spec property to be defined."; pure (VNoval, Just e)

makeRequestUtil :: Context -> UResult
makeRequestUtil ctx = do
  out <- readIORef (cOut ctx)
  pre <- getp out "request"
  isE <- isErr pre
  if isE then pure (VNoval, Just pre)
  else case pre of
    VMap _ -> pure (pre, Nothing)
    _ -> do
      response0 <- newResponse =<< emptyMap
      result <- newResult =<< emptyMap
      writeIORef (cResult ctx) result
      specV <- readIORef (cSpec ctx)
      case specV of
        VMap _ -> do
          (fetchdef, merr) <- makeFetchDefUtil ctx
          case merr of
            Just e -> do
              setp response0 "err" e
              writeIORef (cResponse ctx) response0
              setp specV "step" (VStr "postrequest")
              pure (response0, Nothing)
            Nothing -> do
              ctrl <- readIORef (cCtrl ctx)
              explain <- getp ctrl "explain"
              case explain of VMap _ -> setp explain "fetchdef" fetchdef; _ -> pure ()
              setp specV "step" (VStr "prerequest")
              url <- getStrD fetchdef "url" ""
              u <- cu ctx
              fetcher <- readIORef (uFetcher u)
              (fetched, fetchErr) <- fetcher ctx url fetchdef
              response <- case fetchErr of
                Just fe -> do setp response0 "err" fe; pure response0
                Nothing ->
                  if isNoval fetched || isNullV fetched
                    then do r <- newResponse =<< emptyMap; e <- mkErr "request_no_response" "response: undefined"; setp r "err" e; pure r
                    else case fetched of
                      VMap _ -> newResponse fetched
                      _ -> do setp response0 "err" =<< mkErr "request_invalid_response" "response: invalid type"; pure response0
              setp specV "step" (VStr "postrequest")
              writeIORef (cResponse ctx) response
              pure (response, Nothing)
        _ -> do e <- mkErr "request_no_spec" "Expected context spec property to be defined."; pure (VNoval, Just e)

isNullV :: Value -> Bool
isNullV VNull = True
isNullV _ = False

makeResponseUtil :: Context -> UResult
makeResponseUtil ctx = do
  out <- readIORef (cOut ctx)
  pre <- getp out "response"
  isE <- isErr pre
  if isE then pure (VNoval, Just pre)
  else case pre of
    VMap _ -> pure (pre, Nothing)
    _ -> do
      specV <- readIORef (cSpec ctx)
      responseV <- readIORef (cResponse ctx)
      resultV <- readIORef (cResult ctx)
      case specV of
        VMap _ -> case responseV of
          VMap _ -> case resultV of
            VMap _ -> do
              setp specV "step" (VStr "response")
              resultBasicUtil ctx; resultHeadersUtil ctx; resultBodyUtil ctx
              -- GraphQL reports failures as a top-level `errors` array under
              -- HTTP 200, so resultBasic's status check never sees them. Lift
              -- them here, before the response transform tries to unwrap data
              -- that is not there.
              _ <- graphqlErrorsUtil ctx
              _ <- transformResponseUtil ctx
              errv <- getp resultV "err"
              isErrR <- isErr errv
              when (not isErrR) (setp resultV "ok" (VBool True))
              ctrl <- readIORef (cCtrl ctx)
              explain <- getp ctrl "explain"
              case explain of { VMap _ -> do { snap <- resultToValue resultV; setp explain "result" snap }; _ -> pure () }
              pure (responseV, Nothing)
            _ -> do e <- mkErr "response_no_result" "Expected context result property to be defined."; pure (VNoval, Just e)
          _ -> do e <- mkErr "response_no_response" "Expected context response property to be defined."; pure (VNoval, Just e)
        _ -> do e <- mkErr "response_no_spec" "Expected context spec property to be defined."; pure (VNoval, Just e)

makeResultUtil :: Context -> UResult
makeResultUtil ctx = do
  out <- readIORef (cOut ctx)
  pre <- getp out "result"
  isE <- isErr pre
  if isE then pure (VNoval, Just pre)
  else case pre of
    VMap _ -> pure (pre, Nothing)
    _ -> do
      op <- readIORef (cOp ctx)
      specV <- readIORef (cSpec ctx)
      resultV <- readIORef (cResult ctx)
      case specV of
        VMap _ -> case resultV of
          VMap _ -> do
            setp specV "step" (VStr "result")
            _ <- transformResponseUtil ctx
            when (opName op == "list") $ do
              resdata <- getp resultV "resdata"
              el <- emptyList
              setp resultV "resdata" el
              ment <- readIORef (cEntity ctx)
              case (resdata, ment) of
                (VList _, Just entity) -> do
                  items0 <- listItems resdata
                  entries <- mapM (\entry -> do
                    ent <- eMake entity
                    case entry of VMap _ -> eDataSet ent entry; _ -> pure ()
                    pure entry) items0
                  el2 <- mkList entries
                  setp resultV "resdata" el2
                _ -> pure ()
            ctrl <- readIORef (cCtrl ctx)
            explain <- getp ctrl "explain"
            case explain of { VMap _ -> do { snap <- resultToValue resultV; setp explain "result" snap }; _ -> pure () }
            pure (resultV, Nothing)
          _ -> do e <- mkErr "result_no_result" "Expected context result property to be defined."; pure (VNoval, Just e)
        _ -> do e <- mkErr "result_no_spec" "Expected context spec property to be defined."; pure (VNoval, Just e)

-- ----- fetcher (innermost transport) -----

fetcherUtil :: Context -> String -> Value -> IO (Value, Maybe Value)
fetcherUtil ctx fullurl fetchdef = do
  cl <- cc ctx
  mode <- readIORef (clMode cl)
  if mode /= "live"
    then do e <- mkErr "fetch_mode_block" ("Request blocked by mode: \"" ++ mode ++ "\" (URL was: \"" ++ fullurl ++ "\")"); pure (VNoval, Just e)
    else do
      options <- clientOptionsMap cl
      testActive <- getpathS options "feature.test.active"
      if isTrueV testActive
        then do e <- mkErr "fetch_test_block" ("Request blocked as test feature is active (URL was: \"" ++ fullurl ++ "\")"); pure (VNoval, Just e)
        else do
          sysFetch <- getpathS options "system.fetch"
          case sysFetch of
            VFunc _ -> do
              argsL <- ja [VStr fullurl, fetchdef]
              out <- callVfn sysFetch argsL
              errStr <- getStr out "__err__"
              case errStr of
                Just msg -> do e <- mkErr "fetch_system" msg; pure (VNoval, Just e)
                Nothing -> pure (out, Nothing)
            VNoval -> do e <- mkErr "fetch_no_transport" "No live HTTP transport in this build; provide options.system.fetch."; pure (VNoval, Just e)
            VNull -> do e <- mkErr "fetch_no_transport" "No live HTTP transport in this build; provide options.system.fetch."; pure (VNoval, Just e)
            _ -> do e <- mkErr "fetch_invalid" "system.fetch is not a valid function"; pure (VNoval, Just e)

-- ------------------------------------------------------------------
-- make_options
-- ------------------------------------------------------------------

optSpecValue :: IO Value
optSpecValue = do
  auth <- jo [("prefix", VStr ""), ("basic", VBool False)]
  hdrs <- jo [("`$CHILD`", VStr "`$STRING`")]
  -- OpenAPI server-variable defaults, carried by the generated config whenever
  -- the spec's server URL is templated. Accepted here so validation does not
  -- reject the SDK's own config; the {name} substitution into base is a
  -- separate concern.
  srv <- jo [("`$CHILD`", VStr "")]
  allow <- jo [("method", VStr "GET,PUT,POST,PATCH,DELETE,OPTIONS"), ("op", VStr "create,update,load,list,remove,command,direct,graphql")]
  entChild <- do a <- emptyMap; jo [("`$OPEN`", VBool True), ("active", VBool False), ("alias", a)]
  ent <- jo [("`$CHILD`", entChild)]
  featChild <- jo [("`$OPEN`", VBool True), ("active", VBool False)]
  feat <- jo [("`$CHILD`", featChild)]
  utilm <- emptyMap
  sysm <- emptyMap
  testEnt <- jo [("`$OPEN`", VBool True)]
  test <- jo [("active", VBool False), ("entity", testEnt)]
  clean <- jo [("keys", VStr "key,token,id")]
  jo [ ("apikey", VStr ""), ("base", VStr "http://localhost:8000"), ("prefix", VStr ""), ("suffix", VStr "")
     , ("auth", auth), ("headers", hdrs), ("server", srv), ("allow", allow), ("entity", ent), ("feature", feat)
     , ("utility", utilm), ("system", sysm), ("test", test), ("clean", clean) ]

makeOptionsUtil :: Context -> IO Value
makeOptionsUtil ctx = do
  optionsV <- readIORef (cOptions ctx)
  options <- case optionsV of VNoval -> emptyMap; v -> pure v
  customUtils <- getp options "utility"
  case customUtils of
    VMap _ -> do
      mu <- readIORef (cUtility ctx)
      case mu of
        Just u -> do ks <- keysof customUtils; forM_ ks $ \k -> do v <- getp customUtils k; c <- readIORef (uCustom u); setp c k v
        Nothing -> pure ()
    _ -> pure ()
  optsC <- clone options
  opts0 <- case optsC of VMap _ -> pure optsC; _ -> emptyMap
  -- Feature add-order. options.feature may be given as an ordered LIST of
  -- {name, active, ...opts} entries (list position = add order) or a
  -- {name => {opts}} map. Normalize a list to a map (so merge/validate/init
  -- are unchanged) and remember the explicit order; a map defaults to
  -- test-first so the `test` mock transport is the base of the wrapper chain.
  featureRaw <- getp opts0 "feature"
  explicitOrder <- case featureRaw of
    VList ref -> do
      entries <- readIORef ref
      fmap' <- emptyMap
      order <- fmap concat $ mapM (\entry -> case entry of
        VMap _ -> do
          nm <- getp entry "name"
          case nm of
            VStr name -> do
              fopts <- clone entry
              _ <- delprop fopts (VStr "name")
              setp fmap' name fopts
              pure [name]
            _ -> pure []
        _ -> pure []) entries
      setp opts0 "feature" fmap'
      pure (Just order)
    _ -> pure Nothing
  configV <- readIORef (cConfig ctx)
  config <- case configV of VMap _ -> pure configV; _ -> emptyMap
  cfgoptsV <- toMap <$> getp config "options"
  cfgopts <- case cfgoptsV of VMap _ -> pure cfgoptsV; _ -> emptyMap
  optspec <- optSpecValue
  sysFetch <- getpathS opts0 "system.fetch"
  em <- emptyMap
  mlist <- ja [em, cfgopts, opts0]
  merged <- merge mlist
  validated <- validate INone merged optspec
  opts <- case validated of VMap _ -> pure validated; _ -> emptyMap
  -- Resolve a templated base URL (e.g. https://{tenant_id}.hanko.io).
  -- Every placeholder must resolve to a non-empty value: from options.server
  -- (user), else the Config default. A placeholder that resolves to "" is a
  -- construction ERROR in live mode - the URL cannot work - but in test mode
  -- substitutes the deterministic value "test-<name>" so offline tests need no
  -- configuration. The SDK constructor has no error return, so a missing
  -- required variable THROWS: construction-time misconfiguration.
  baseV <- getp opts "base"
  case baseV of
    VStr base | '{' `elem` base -> do
      taV <- getpathS opts "test.active"
      faV <- getpathS opts "feature.test.active"
      -- Value has no Eq instance: match the constructor.
      let isTrue v = case v of VBool b -> b; _ -> False
          testmode = isTrue taV || isTrue faV
      server <- getp opts "server"
      mnV <- getpathS config "main.name"
      let sdkname = case mnV of VStr s | not (null s) -> s; _ -> "SDK"

      -- Scanned by hand: a placeholder is `{` followed by [A-Za-z0-9_]+ and
      -- `}`; anything else is literal text, so a stray brace is left alone.
      let resolve [] = pure []
          resolve ('{' : rest) =
            let (name, tail') = span (\c -> isAlphaNum c || '_' == c) rest
            in case tail' of
                 ('}' : more) | not (null name) -> do
                   valV <- case server of VMap _ -> getp server name; _ -> pure VNoval
                   let val = case valV of VStr s -> s; _ -> ""
                   sub <- if not (null val)
                     then pure val
                     else if testmode
                       then pure ("test-" ++ name)
                       else do
                         e <- jo [ ("code", VStr "server_var_required")
                                 , ("msg", VStr (sdkname ++ ": the server variable '" ++
                                     name ++ "' is required: the API base URL is '" ++
                                     base ++ "' - pass server = { \"" ++ name ++
                                     "\": \"...\" } in the SDK options"))
                                 , ("sdk", VStr "Univec") ]
                         throwIO (SdkException e)
                   more' <- resolve more
                   pure (sub ++ more')
                 _ -> do r <- resolve rest; pure ('{' : r)
          resolve (c : rest) = do r <- resolve rest; pure (c : r)
      resolved <- resolve base
      setp opts "base" (VStr resolved)
    _ -> pure ()

  when (not (isNoval sysFetch)) $ do
    sys <- getp opts "system"
    case sys of
      VMap _ -> setp sys "fetch" sysFetch
      _ -> do s <- jo [("fetch", sysFetch)]; setp opts "system" s
  ckv <- getpathS opts "clean.keys"
  let cleanKeys = case ckv of VStr s -> s; _ -> "key,token,id"
  parts <- fmap concat $ mapM (\p -> let t = strip p in if t == "" then pure [] else do e <- escreS t; pure [e]) (splitOnChar ',' cleanKeys)
  let keyre = intercalate' "|" parts
  cleanEmpty <- emptyMap
  derived <- jo [("clean", cleanEmpty)]
  when (keyre /= "") $ do cm <- jo [("keyre", VStr keyre)]; setp derived "clean" cm
  -- Resolve the feature add-order: an explicit list order (above) wins;
  -- otherwise order the map test-first, then the remaining names sorted
  -- (keysof returns sorted keys), so the result is deterministic.
  featureOrder <- case explicitOrder of
    Just ord -> pure ord
    Nothing -> do
      fmapV <- getp opts "feature"
      names <- case fmapV of VMap _ -> keysof fmapV; _ -> pure []
      pure $ if "test" `elem` names then "test" : filter (/= "test") names else names
  orderList <- ja (map VStr featureOrder)
  setp derived "featureorder" orderList
  setp opts "__derived__" derived
  pure opts

intercalate' :: String -> [String] -> String
intercalate' _ [] = ""
intercalate' _ [x] = x
intercalate' sep (x : xs) = x ++ sep ++ intercalate' sep xs

-- ------------------------------------------------------------------
-- struct api exposure (utility.struct)
-- ------------------------------------------------------------------

structApiInstance :: StructApi
structApiInstance = StructApi
  { sGetprop = getprop
  , sSetprop = setprop
  , sGetpath = getpath INone
  , sGetelem = getelem
  , sClone = clone
  , sMerge = \l -> mkList l >>= merge
  , sItems = items
  , sKeysof = keysof
  , sSize = size
  , sIsempty = isempty
  , sStringify = stringify
  , sJsonify = jsonifyCompact
  , sEscurl = escurlS . vstring
  , sEscre = escreS . vstring
  , sTransform = transform INone
  , sValidate = validate INone
  , sSelect = select
  , sWalk = \fn v -> walk (Just fn) Nothing VNoval v
  }

-- ------------------------------------------------------------------
-- utility construction
-- ------------------------------------------------------------------

newUtility :: IO Utility
newUtility = do
  custom <- newIORef =<< emptyMap
  fetcher <- newIORef fetcherUtil
  param <- newIORef paramUtil
  pure Utility { uCustom = custom, uStruct = structApiInstance, uFetcher = fetcher, uParam = param }

copyUtility :: Utility -> IO Utility
copyUtility src = do
  f <- readIORef (uFetcher src)
  p <- readIORef (uParam src)
  fetcher <- newIORef f
  param <- newIORef p
  srcCustom <- readIORef (uCustom src)
  custom <- emptyMap
  case srcCustom of
    VMap _ -> do ks <- keysof srcCustom; forM_ ks $ \k -> do v <- getp srcCustom k; setp custom k v
    _ -> pure ()
  customR <- newIORef custom
  pure Utility { uCustom = customR, uStruct = uStruct src, uFetcher = fetcher, uParam = param }

-- struct join helper: join parts with "/" as a URL path
join_ :: Value -> IO String
join_ arr = join arr (VStr "/") True
