-- Univec SDK value helpers — thin wrappers over the vendored voxgig
-- struct `Value` type used throughout the pipeline, plus the pipeline-object
-- constructors (spec/response/result/operation/control are struct maps).

module SdkHelpers where

import Data.Char (toLower, toUpper)
import Data.IORef
import Data.List (isPrefixOf)

import VoxgigStruct
  ( Value (..), InjArg (..), dummyInj, emptyList, emptyMap, mkList, mkMap
  , getprop, getpropAlt, setprop, delprop, getpath, getelem, keysof, listItems
  , clone, isnode, ismap, islist, isfunc, iskey, isNoval, isNullish, vint
  , vIsTrue, vStrEq, jsonEncode )

import SdkTypes

-- ----- map / list construction & access -----

jo :: [(String, Value)] -> IO Value
jo = mkMap

ja :: [Value] -> IO Value
ja = mkList

getp :: Value -> String -> IO Value
getp v k = getprop v (VStr k)

setp :: Value -> String -> Value -> IO ()
setp v k nv = () <$ setprop v (VStr k) nv

delp :: Value -> String -> IO ()
delp v k = () <$ delprop v (VStr k)

getpathS :: Value -> String -> IO Value
getpathS store p = getpath INone store (VStr p)

toMap :: Value -> Value
toMap v = case v of VMap _ -> v; _ -> VNoval

toInt :: Value -> Int
toInt v = case v of VNum n -> truncate n; _ -> -1

getStr :: Value -> String -> IO (Maybe String)
getStr m k = (\v -> case v of VStr s -> Just s; _ -> Nothing) <$> getp m k

getStrD :: Value -> String -> String -> IO String
getStrD m k d = maybe d id <$> getStr m k

getBool :: Value -> String -> IO (Maybe Bool)
getBool m k = (\v -> case v of VBool b -> Just b; _ -> Nothing) <$> getp m k

getNum :: Value -> String -> IO (Maybe Double)
getNum m k = (\v -> case v of VNum n -> Just n; _ -> Nothing) <$> getp m k

isTrueV :: Value -> Bool
isTrueV = vIsTrue

vlistItems :: Value -> IO [Value]
vlistItems = listItems

-- ----- string form of a value (JS String(v)) -----

vstring :: Value -> String
vstring v = case v of
  VStr s -> s
  VNoval -> ""
  VNull -> ""
  VBool b -> if b then "true" else "false"
  VNum n -> numToStr n
  _ -> ""

numToStr :: Double -> String
numToStr n = if fromIntegral (truncate n :: Integer) == n
             then show (truncate n :: Integer)
             else show n

lower :: String -> String
lower = map toLower

upper :: String -> String
upper = map toUpper

-- ----- callables (struct Func) -----

callVfn :: Value -> Value -> IO Value
callVfn fn arg = case fn of VFunc f -> f dummyInj arg "" VNoval; _ -> pure VNoval

callJson :: Value -> IO Value
callJson j = callVfn j VNoval

jsonThunk :: Value -> Value
jsonThunk d = VFunc (\_ _ _ _ -> pure d)

vfunc0 :: IO Value -> Value
vfunc0 f = VFunc (\_ _ _ _ -> f)

vfunc1 :: (Value -> IO Value) -> Value
vfunc1 f = VFunc (\_ v _ _ -> f v)

isCallable :: Value -> Bool
isCallable = isfunc

-- ----- errors (Value maps tagged __sdkerr__) -----

mkErr :: String -> String -> IO Value
mkErr code msg = jo
  [ ("__sdkerr__", VBool True)
  , ("code", VStr code)
  , ("message", VStr msg)
  , ("result", VNoval)
  , ("spec", VNoval) ]

ctxMakeError :: Context -> String -> String -> IO Value
ctxMakeError _ = mkErr

isErr :: Value -> IO Bool
isErr v = case v of
  VMap _ -> (\t -> case t of VBool True -> True; _ -> False) <$> getp v "__sdkerr__"
  _ -> pure False

errMsg :: Value -> IO String
errMsg e = getStrD e "message" ""

errCode :: Value -> IO String
errCode e = getStrD e "code" ""

errToValue :: Value -> IO Value
errToValue e = do
  c <- errCode e; m <- errMsg e
  jo [("code", VStr c), ("message", VStr m)]

-- ----- ctx utility / client unwrap -----

cu :: Context -> IO Utility
cu ctx = do
  m <- readIORef (cUtility ctx)
  case m of Just u -> pure u; Nothing -> error "context utility not set"

cc :: Context -> IO Client
cc ctx = do
  m <- readIORef (cClient ctx)
  case m of Just c -> pure c; Nothing -> error "context client not set"

-- ----- per-op feature scratch (cScratch map) -----

scratchGet :: Context -> String -> IO Value
scratchGet ctx k = do s <- readIORef (cScratch ctx); getp s k

scratchSet :: Context -> String -> Value -> IO ()
scratchSet ctx k v = do s <- readIORef (cScratch ctx); setp s k v

scratchDel :: Context -> String -> IO ()
scratchDel ctx k = do s <- readIORef (cScratch ctx); delp s k

-- ----- client feature-tracking sink (client._retry / _cache / ...) -----

trackGet :: Client -> String -> IO Value
trackGet cl name = do t <- readIORef (clTrack cl); getp t name

trackSet :: Client -> String -> Value -> IO ()
trackSet cl name v = do t <- readIORef (clTrack cl); setp t name v

trackBucket :: Client -> String -> IO Value -> IO Value
trackBucket cl name mk = do
  b <- trackGet cl name
  case b of
    VMap _ -> pure b
    _ -> do nb <- mk; trackSet cl name nb; pure nb

bumpNum :: Value -> String -> Double -> IO ()
bumpNum m k by = do
  cur <- getp m k
  let c = case cur of VNum n -> n; _ -> 0
  setp m k (VNum (c + by))

-- ----- header lookup (case-insensitive) over a struct map -----

headerCI :: Value -> String -> IO Value
headerCI headers name = do
  ks <- keysof headers
  let ln = lower name
      go [] = pure VNoval
      go (k : rest) = if lower k == ln then getp headers k else go rest
  go ks

-- ----- JSON compact encode (for request bodies) -----

jsonifyCompact :: Value -> IO String
jsonifyCompact v = jsonEncode False Nothing v

-- ----- pipeline-object constructors (Value maps) -----

newControl :: IO Value
newControl = jo
  [ ("throw", VNoval), ("err", VNoval), ("explain", VNoval)
  , ("actor", VNoval), ("paging", VNoval) ]

newOperation :: Value -> IO Operation
newOperation m = do
  ent <- gstr "entity"; nm <- gstr "name"; inp <- gstr "input"
  ptsV <- getp m "points"
  pts <- case ptsV of VList _ -> filterMaps ptsV; _ -> emptyList
  aliasV <- getp m "alias"
  let alias = case aliasV of VMap _ -> aliasV; _ -> VNoval
  pure (Operation ent nm inp pts alias)
  where
    gstr k = do
      v <- getp m k
      pure (case v of VStr s | s /= "" -> s; _ -> "_")
    filterMaps l = do its <- listItems l; mkList [x | x <- its, ismap x]

newSpec :: Value -> IO Value
newSpec m = do
  parts <- gv "parts" emptyList
  headers <- gv "headers" emptyMap
  alias <- gv "alias" emptyMap
  params <- gv "params" emptyMap
  query <- gv "query" emptyMap
  base <- gs "base"; prefix <- gs "prefix"; suffix <- gs "suffix"; step <- gs "step"
  method <- gsD "method" "GET"; path <- gs "path"; url <- gs "url"
  body <- getp m "body"
  jo [ ("parts", parts), ("headers", headers), ("alias", alias)
     , ("base", VStr base), ("prefix", VStr prefix), ("suffix", VStr suffix)
     , ("params", params), ("query", query), ("step", VStr step)
     , ("method", VStr method), ("body", body), ("url", VStr url), ("path", VStr path) ]
  where
    gs k = do v <- getp m k; pure (case v of VStr s -> s; _ -> "")
    gsD k d = do v <- getp m k; pure (case v of VStr s -> s; _ -> d)
    gv k dfl = do v <- getp m k; case v of VNoval -> dfl; _ -> pure v

newResponse :: Value -> IO Value
newResponse m = do
  sv <- getp m "status"
  let status = case sv of VNum n -> truncate n :: Int; _ -> -1
  st <- getStrD m "statusText" ""
  headers <- getp m "headers"
  jv <- getp m "json"
  let jsn = case jv of VFunc _ -> jv; _ -> VNoval
  body <- getp m "body"
  jo [ ("status", vint status), ("statusText", VStr st), ("headers", headers)
     , ("json", jsn), ("body", body), ("err", VNoval) ]

newResult :: Value -> IO Value
newResult m = do
  okv <- getp m "ok"
  let ok = case okv of VBool True -> True; _ -> False
  sv <- getp m "status"
  let status = case sv of VNum n -> truncate n :: Int; _ -> -1
  st <- getStrD m "statusText" ""
  hv <- getp m "headers"
  headers <- case hv of VMap _ -> pure hv; _ -> emptyMap
  body <- getp m "body"
  resdata <- getp m "resdata"
  rmv <- getp m "resmatch"
  let resmatch = case rmv of VMap _ -> rmv; _ -> VNoval
  jo [ ("ok", VBool ok), ("status", vint status), ("statusText", VStr st)
     , ("headers", headers), ("body", body), ("err", VNoval)
     , ("resdata", resdata), ("resmatch", resmatch), ("paging", VNoval)
     , ("streaming", VBool False), ("stream", VNoval) ]

-- Match-map snapshots for explain records / attached error payloads.
specToValue :: Value -> IO Value
specToValue = clone

resultToValue :: Value -> IO Value
resultToValue rt = do
  out <- emptyMap
  ok <- getp rt "ok"; setp out "ok" ok
  status <- getp rt "status"; setp out "status" status
  st <- getp rt "statusText"; setp out "statusText" st
  hdr <- getp rt "headers"; setp out "headers" hdr
  body <- getp rt "body"
  case body of VNoval -> pure (); _ -> setp out "body" body
  err <- getp rt "err"
  isE <- isErr err
  if isE then do em <- getp err "message"; emap <- jo [("message", em)]; setp out "err" emap else pure ()
  resdata <- getp rt "resdata"
  case resdata of VNoval -> pure (); _ -> setp out "resdata" resdata
  resmatch <- getp rt "resmatch"
  case resmatch of VNoval -> pure (); _ -> setp out "resmatch" resmatch
  paging <- getp rt "paging"
  case paging of VNoval -> pure (); _ -> setp out "paging" paging
  pure out

-- Operation resolution key
opCacheKey :: String -> String -> String
opCacheKey ent op = ent ++ ":" ++ op

-- Small local string helpers
substrContains :: String -> String -> Bool
substrContains hay needle
  | null needle = True
  | otherwise = go hay
  where
    go [] = False
    go s@(_ : rest) = needle `isPrefixOf` s || go rest

strReplaceAll :: String -> String -> String -> String
strReplaceAll s find repl
  | null find = s
  | otherwise = go s
  where
    fl = length find
    go [] = []
    go xs@(c : cs)
      | take fl xs == find = repl ++ go (drop fl xs)
      | otherwise = c : go cs

splitOnChar :: Char -> String -> [String]
splitOnChar c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOnChar c rest

strip :: String -> String
strip = f . f where f = reverse . dropWhile (== ' ')

-- ----- config literal builder (used by the generated SdkConfig) -----

-- | A pure config literal the generator emits; `buildCV` realises it as a
-- struct 'Value' (the config is JSON-shaped API model data).
data CV
  = CVNull
  | CVStr String
  | CVNum Double
  | CVBool Bool
  | CVList [CV]
  | CVMap [(String, CV)]

buildCV :: CV -> IO Value
buildCV CVNull = pure VNull
buildCV (CVStr s) = pure (VStr s)
buildCV (CVNum n) = pure (VNum n)
buildCV (CVBool b) = pure (VBool b)
buildCV (CVList xs) = mapM buildCV xs >>= mkList
buildCV (CVMap kvs) = mapM (\(k, v) -> (,) k <$> buildCV v) kvs >>= mkMap
