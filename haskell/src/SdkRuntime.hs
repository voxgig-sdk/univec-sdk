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

import Control.Exception (throwIO, try)
import Control.Monad (forM_, when)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.Char (chr, isAlphaNum, isHexDigit, isSpace, digitToInt, ord, toLower, toUpper)
import Data.IORef
import Data.List (dropWhileEnd, intercalate, isInfixOf, isSuffixOf, nub, sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Ord (Down (..), comparing)
import System.IO.Unsafe (unsafePerformIO)
import Text.Printf (printf)
import Text.Read (readMaybe)

import VoxgigStruct
  ( Value (..), InjArg (..), StructError (..), emptyList, emptyMap, mkList, mkMap
  , getprop, getpropAlt, setprop, delprop, getpath, getelem, keysof, listItems
  , items, clone, merge, validate, transform, select, size, isempty
  , isnode, ismap, islist, isfunc, isNoval, isNullish, vint
  , escurl, escre, stringify, walk, join, jsonEncode )
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
          let inpt = if opname `elem` ["update", "create", "patch"] then "data" else "match"
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

-- ----- clean: what leaves the pipeline is masked -----
--
-- Everything that leaves the pipeline passes through cleanUtil; inside it
-- data stays raw, so a hook can still read the header it must add to. See
-- the generator's docs/explanation/secret-redaction.md.

cleanMaxDepth :: Int
cleanMaxDepth = 32

cleanCircular :: String
cleanCircular = "[circular]"

-- The `clean` block of the option spec (main.kit.optspec.clean in the sdkgen
-- base model), held here because this pack's targets read no generated
-- Schema module. Numbers are strings, like every optspec value.
cleanOptSpec :: IO Value
cleanOptSpec = jo
  [ ("active", VBool True)
  , ("keys", VStr "key,secret,token,password,passwd,authorization,cookie,credential,signature")
  , ("values", VStr "")
  , ("mask", VStr "[redacted]")
  , ("hint", VStr "0")
  , ("min", VStr "4") ]

normkey :: String -> String
normkey = filter (\c -> c /= '-' && c /= '_') . lower

splitkeys :: Value -> [String]
splitkeys v = filter (/= "") (map (normkey . strip) (splitOnChar ',' (vstring v)))

splitvalues :: Value -> IO [String]
splitvalues v = case v of
  VList _ -> do its <- listItems v; pure [s | VStr s <- its]
  VStr s -> pure (filter (/= "") (map strip (splitOnChar ',' s)))
  _ -> pure []

countOpt :: Value -> Int -> Int
countOpt v dflt = case v of
  VNum n | n >= 0 -> clampCount n
  VStr s -> case readMaybe s :: Maybe Double of
    Just n | n >= 0 -> clampCount n
    _ -> dflt
  _ -> dflt

-- floor of a Double beyond the Int range is undefined, so a count caps.
clampCount :: Double -> Int
clampCount n = if n >= fromIntegral (maxBound :: Int) then maxBound else floor n

-- The derived clean block is a map, so features can register into its
-- `values` list after makeOptions; `keys` holds the normalised names.
makeCleanConfig :: Value -> IO Value
makeCleanConfig cleanopts = do
  opts <- case cleanopts of VMap _ -> pure cleanopts; _ -> emptyMap
  activeV <- getp opts "active"
  keysV <- getp opts "keys"
  maskV <- getp opts "mask"
  hintV <- getp opts "hint"
  minV <- getp opts "min"
  keys <- ja (map VStr (splitkeys keysV))
  values <- emptyList
  jo [ ("active", VBool (case activeV of VBool False -> False; _ -> True))
     , ("keys", keys), ("values", values)
     , ("mask", VStr (case maskV of VStr m -> m; _ -> "[redacted]"))
     , ("hint", vint (countOpt hintV 0))
     , ("min", vint (max 1 (countOpt minV 4))) ]

-- A context without options (makeError accepts a bare one) still masks by
-- the schema defaults.
cleanConfigOf :: Context -> IO Value
cleanConfigOf ctx = do
  options <- readIORef (cOptions ctx)
  derived <- case options of VMap _ -> getpathS options "__derived__.clean"; _ -> pure VNoval
  case derived of
    VMap _ -> pure derived
    _ -> makeCleanConfig =<< cleanOptSpec

data CleanRule = CleanRule
  { crActive :: Bool
  , crMask   :: String
  , crHint   :: Int
  , crKeys   :: [String]
  , crValues :: [String]
  }

cfgStrings :: Value -> String -> IO [String]
cfgStrings cfg k = do
  v <- getp cfg k
  case v of { VList _ -> do { its <- listItems v; pure [s | VStr s <- its] }; _ -> pure [] }

cfgInt :: Value -> String -> Int -> IO Int
cfgInt cfg k d = do v <- getp cfg k; pure (case v of VNum n -> clampCount n; _ -> d)

cleanRule :: Value -> IO CleanRule
cleanRule cfg = do
  activeV <- getp cfg "active"
  mask <- getStrD cfg "mask" "[redacted]"
  hint <- cfgInt cfg "hint" 0
  keys <- cfgStrings cfg "keys"
  values <- cfgStrings cfg "values"
  pure CleanRule { crActive = case activeV of VBool False -> False; _ -> True
                 , crMask = mask, crHint = hint, crKeys = keys, crValues = values }

utf8Bytes :: String -> [Int]
utf8Bytes = concatMap enc
  where
    enc c
      | n < 0x80 = [n]
      | n < 0x800 = [0xC0 .|. (n `shiftR` 6), 0x80 .|. (n .&. 0x3F)]
      | n < 0x10000 = [0xE0 .|. (n `shiftR` 12), 0x80 .|. ((n `shiftR` 6) .&. 0x3F), 0x80 .|. (n .&. 0x3F)]
      | otherwise = [0xF0 .|. (n `shiftR` 18), 0x80 .|. ((n `shiftR` 12) .&. 0x3F), 0x80 .|. ((n `shiftR` 6) .&. 0x3F), 0x80 .|. (n .&. 0x3F)]
      where n = ord c

base64Encode :: String -> String
base64Encode s = go (utf8Bytes s)
  where
    tbl = ['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['0' .. '9'] ++ "+/"
    at i = tbl !! (i .&. 63)
    go (a : b : c : rest) =
      let n = (a `shiftL` 16) .|. (b `shiftL` 8) .|. c
      in [at (n `shiftR` 18), at (n `shiftR` 12), at (n `shiftR` 6), at n] ++ go rest
    go [a, b] =
      let n = (a `shiftL` 16) .|. (b `shiftL` 8)
      in [at (n `shiftR` 18), at (n `shiftR` 12), at (n `shiftR` 6), '=']
    go [a] =
      let n = a `shiftL` 16
      in [at (n `shiftR` 18), at (n `shiftR` 12), '=', '=']
    go [] = []

-- The decoded form, as decodeURIComponent reads it: the escapes are UTF-8
-- octets, and a malformed escape or sequence has no decoded form.
percentDecode :: String -> Maybe String
percentDecode = go []
  where
    go acc ('%' : a : b : rest)
      | isHexDigit a && isHexDigit b = go ((digitToInt a * 16 + digitToInt b) : acc) rest
    go _ ('%' : _) = Nothing
    go acc (c : rest) = go (reverse (utf8Bytes [c]) ++ acc) rest
    go acc [] = utf8Decode (reverse acc)

-- Strict UTF-8: an overlong, surrogate, out-of-range or truncated sequence
-- is Nothing.
utf8Decode :: [Int] -> Maybe String
utf8Decode [] = Just []
utf8Decode (b : rest)
  | b < 0x80 = (chr b :) <$> utf8Decode rest
  | b >= 0xC2 && b < 0xE0 = multi 1 (b .&. 0x1F) 0x80
  | b >= 0xE0 && b < 0xF0 = multi 2 (b .&. 0x0F) 0x800
  | b >= 0xF0 && b < 0xF5 = multi 3 (b .&. 0x07) 0x10000
  | otherwise = Nothing
  where
    multi n lead lo = case splitAt n rest of
      (cs, more) | length cs == n && all (\c -> c .&. 0xC0 == 0x80) cs ->
        let cp = foldl (\a c -> (a `shiftL` 6) .|. (c .&. 0x3F)) lead cs
        in if cp < lo || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) then Nothing
           else (chr cp :) <$> utf8Decode more
      _ -> Nothing

-- The encoded forms a value travels in.
cleanForms :: String -> IO [String]
cleanForms value = do
  pe <- escurlS value
  js <- jsonEncode False Nothing (VStr value)
  let jsIn = if length js >= 2 then init (tail js) else js
  pure (nub (filter (/= "") [value, base64Encode value, pe, jsIn]))

cleanAddCfg :: Value -> Value -> IO ()
cleanAddCfg cfg value = do
  minLen <- cfgInt cfg "min" 4
  case value of
    VStr s | length s >= minLen -> do
      forms <- cleanForms s
      valuesV <- getp cfg "values"
      case valuesV of
        VList r -> do
          cur <- readIORef r
          let have = [x | VStr x <- cur]
              new = [f | f <- forms, length f >= minLen, f `notElem` have]
          when (not (null new)) $
            writeIORef r (map VStr (sortBy (comparing (Down . length)) (have ++ new)))
        _ -> pure ()
    _ -> pure ()

cleanAddUtil :: Context -> Value -> IO ()
cleanAddUtil ctx value = do cfg <- cleanConfigOf ctx; cleanAddCfg cfg value

-- The hint is compared as a difference: 2 * hint overflows for a large one.
maskValue :: CleanRule -> String -> String
maskValue r value =
  let h = crHint r
      n = length value
  in if h > 0 && n - h > h then crMask r ++ drop (n - h) value else crMask r

cleanStr :: CleanRule -> String -> String
cleanStr r = \text -> foldl swap text (crValues r)
  where swap out v = if v `isInfixOf` out then strReplaceAll out v (maskValue r v) else out

sensitiveKey :: [String] -> Value -> Bool
sensitiveKey keys key = case key of
  VStr k -> let nk = normkey k in any (`isInfixOf` nk) keys
  _ -> False

cleanKeyUtil :: Context -> Value -> IO Bool
cleanKeyUtil ctx key = do cfg <- cleanConfigOf ctx; keys <- cfgStrings cfg "keys"; pure (sensitiveKey keys key)

-- A node already on the path down: struct nodes are reference-stable, so
-- the IORef is the identity.
data Seen = SeenL (IORef [Value]) | SeenM (IORef [(String, Value)])

instance Eq Seen where
  SeenL a == SeenL b = a == b
  SeenM a == SeenM b = a == b
  _ == _ = False

-- A masked plain-data copy: functions dropped, cycles cut, and nothing
-- shared with the live value, whose spec must stay raw.
snapshot :: CleanRule -> Value -> Int -> [Seen] -> Value -> IO Value
snapshot r key depth seen v = case v of
  VNoval -> pure v
  VNull -> pure v
  VStr s -> pure (VStr (if sensitive then maskValue r s else cleanStr r s))
  VFunc _ -> pure VNoval
  VList ref -> node (SeenL ref) $ do
    its <- readIORef ref
    xs <- mapM (\(i, x) -> snapshot r (vint i) (depth + 1) (SeenL ref : seen) x) (zip [0 :: Int ..] its)
    mkList xs
  VMap ref -> node (SeenM ref) $ do
    es <- readIORef ref
    es' <- mapM (\(k, x) -> do y <- snapshot r (VStr k) (depth + 1) (SeenM ref : seen) x; pure (k, y))
                [(k, x) | (k, x) <- es, not (isfunc x)]
    mkMap (cleanNames r es')
  _ -> pure (if sensitive then VStr (crMask r) else v)
  where
    sensitive = sensitiveKey (crKeys r) key
    node s body
      | depth >= cleanMaxDepth || s `elem` seen = pure (VStr cleanCircular)
      | sensitive = pure (VStr (crMask r))
      | otherwise = body

-- A registered value used as a property name is masked like any other
-- string; names that mask alike take a counter, so none is lost.
cleanNames :: CleanRule -> [(String, Value)] -> [(String, Value)]
cleanNames r = reverse . foldl add []
  where
    add out (k, v) =
      let name = cleanStr r k
          taken n = any ((== n) . fst) out
          bump i = let n = name ++ "#" ++ show i in if taken n then bump (i + 1) else n
      in (if name == k || not (taken name) then name else bump (1 :: Int), v) : out

-- Every scalar under a sensitive name, at any depth and of any shape: a
-- credential mistyped as a map or a number is still a credential, and the
-- validation error that rejects it quotes it.
cleanAddSensitiveCfg :: Value -> Value -> IO ()
cleanAddSensitiveCfg cfg v0 = do
  keys <- cfgStrings cfg "keys"
  let go under depth seen v
        | depth >= cleanMaxDepth = pure ()
        | otherwise = case v of
            VStr _ -> when under (cleanAddCfg cfg v)
            VNum _ -> when under (do t <- stringify v; cleanAddCfg cfg (VStr t))
            VList ref | SeenL ref `notElem` seen -> do
              its <- readIORef ref
              mapM_ (go under (depth + 1) (SeenL ref : seen)) its
            VMap ref | SeenM ref `notElem` seen -> do
              es <- readIORef ref
              mapM_ (\(k, x) -> go (under || sensitiveKey keys (VStr k)) (depth + 1) (SeenM ref : seen) x) es
            _ -> pure ()
  go False (0 :: Int) [] v0

cleanAddSensitiveUtil :: Context -> Value -> IO ()
cleanAddSensitiveUtil ctx v = do cfg <- cleanConfigOf ctx; cleanAddSensitiveCfg cfg v

-- A shallow copy of a map without the named keys; the values are shared.
withoutKeys :: [String] -> Value -> IO Value
withoutKeys ks v = case v of
  VMap ref -> do es <- readIORef ref; mkMap [(k, x) | (k, x) <- es, k `notElem` ks]
  _ -> pure v

-- The keys directly under `feature` name features, not fields: `secrets` is
-- a feature, and its settings are not secrets for sitting under its name.
-- Entity blocks hold per-entity settings and seeded records, never a credential.
addSensitiveOptions :: Value -> [String] -> Value -> IO ()
addSensitiveOptions cfg skip opts = do
  let opt k = case opts of VMap _ -> getp opts k; _ -> pure VNoval
      settings v = cleanAddSensitiveCfg cfg =<< withoutKeys ["entity"] v
  rest <- withoutKeys ("feature" : "entity" : skip) opts
  test <- opt "test"
  case (rest, test) of
    (VMap _, VMap _) -> setp rest "test" =<< withoutKeys ["entity"] test
    _ -> pure ()
  cleanAddSensitiveCfg cfg rest
  feature <- opt "feature"
  case feature of
    VMap ref -> readIORef ref >>= mapM_ (settings . snd)
    VList ref -> readIORef ref >>= mapM_ settings
    _ -> cleanAddSensitiveCfg cfg feature

cleanWithCfg :: Value -> Value -> IO Value
cleanWithCfg cfg v = do
  r <- cleanRule cfg
  if crActive r then snapshot r VNoval 0 [] v else pure v

cleanUtil :: Context -> Value -> IO Value
cleanUtil ctx v = do cfg <- cleanConfigOf ctx; cleanWithCfg cfg v

-- The caller holds its own reference to the explain map, so the cleaned
-- copy is written into that node rather than swapped in beside it.
overwriteMap :: Value -> Value -> IO ()
overwriteMap (VMap dst) (VMap src) = readIORef src >>= writeIORef dst
overwriteMap _ _ = pure ()

cleanExplain :: Context -> IO ()
cleanExplain ctx = do
  ctrl <- readIORef (cCtrl ctx)
  explain <- getp ctrl "explain"
  case explain of
    VMap _ -> do cleaned <- cleanUtil ctx explain; overwriteMap explain cleaned
    _ -> pure ()

-- The serialised context leaves the pipeline (a logger, an error dump), so
-- it is cleaned; the live fields stay raw for the pipeline's own use.
contextToValue :: Context -> IO Value
contextToValue ctx = do
  op <- readIORef (cOp ctx)
  opm <- jo [("entity", VStr (opEntity op)), ("name", VStr (opName op)), ("input", VStr (opInput op))]
  spec <- readIORef (cSpec ctx)
  result <- readIORef (cResult ctx)
  response <- readIORef (cResponse ctx)
  meta <- readIORef (cMeta ctx)
  ment <- readIORef (cEntity ctx)
  record <- jo [ ("id", VStr (cId ctx)), ("op", opm), ("spec", spec)
               , ("entity", maybe VNoval (VStr . eName) ment)
               , ("result", result), ("response", response), ("meta", meta) ]
  cleanUtil ctx record

-- ----- make_error / done -----

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
  msgV <- cleanUtil ctx (VStr ("UnivecSDK: " ++ opname ++ ": " ++ em))
  let msg = vstring msgV
  setp result "err" VNoval
  ctrl <- readIORef (cCtrl ctx)
  -- The stage errors reach here without passing done, so the explain record
  -- is cleaned on this path too.
  cleanExplain ctx
  explain <- getp ctrl "explain"
  case explain of
    VMap _ -> do e2 <- jo [("message", VStr msg)]; setp explain "err" e2
    _ -> pure ()
  ecode <- cleanUtil ctx . VStr =<< errCode err
  -- Cleaned COPIES: masking them can never mask the pipeline's own request.
  rv <- cleanUtil ctx =<< resultToValue result
  specV <- readIORef (cSpec ctx)
  sv <- case specV of VMap _ -> cleanUtil ctx =<< specToValue specV; _ -> pure VNoval
  sdkErr <- jo [ ("__sdkerr__", VBool True), ("code", ecode), ("message", VStr msg)
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
  cleanExplain ctx
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
  base <- case h of
    VNoval -> emptyMap
    _ -> do c <- clone h; case c of VMap _ -> pure c; _ -> emptyMap
  point <- readIORef (cPoint ctx)
  out <- mediaHeaders point base

  -- A header argument replaces a default of the same name, whatever its case.
  hargs <- callArgs ctx "header"
  forM_ hargs $ \(_, wire, val) -> when (not (isNullish val)) $ do
    let key = lowerS wire
    ks <- keysof out
    forM_ ks $ \k -> when (lowerS k == key) (delp out k)
    s <- stringify val
    setp out key (VStr s)

  -- A cookie argument travels in the cookie header, form serialized and
  -- percent-encoded, replacing a same-named cookie the caller's headers send.
  cargs <- callArgs ctx "cookie"
  let sent = filter (\(_, _, val) -> not (isNullish val)) cargs
  when (not (null sent)) $ do
    names <- fmap concat $ mapM (\(_, wire, val) -> case val of
      VMap _ -> keysof val >>= mapM escurlS
      _ -> pure [wire]) sent
    ks <- keysof out
    kept0 <- fmap concat $ mapM (\k -> if lowerS k /= "cookie" then pure [] else do
      v <- getp out k
      delp out k
      pure (case v of VStr s -> cookieKeep s names; _ -> [])) ks
    pairs <- mapM (\(_, wire, val) -> cookiePair wire val) sent
    let kept = kept0 ++ filter (/= "") pairs
    when (not (null kept)) (setp out "cookie" (VStr (intercalate "; " kept)))

  pure out

trimWs :: String -> String
trimWs = dropWhileEnd isSpace . dropWhile isSpace

lowerS :: String -> String
lowerS = map toLower

-- The form style of a cookie parameter: a list repeats the name, a map sends
-- its own keys, and every value is percent-encoded.
cookiePair :: String -> Value -> IO String
cookiePair wire val = do
  let esc v = stringify v >>= escurlS
  pairs <- case val of
    VList _ -> do
      xs <- listItems val
      mapM (\x -> do e <- esc x; pure (wire ++ "=" ++ e)) xs
    VMap _ -> do
      ks <- keysof val
      mapM (\k -> do v <- getp val k; e <- esc v; ek <- escurlS k; pure (ek ++ "=" ++ e)) ks
    _ -> do e <- esc val; pure [wire ++ "=" ++ e]
  pure (intercalate "; " pairs)

-- The caller's cookie pieces with the named cookies removed: a cookie is one
-- `;`-delimited piece, whatever its value holds.
cookieKeep :: String -> [String] -> [String]
cookieKeep header names =
  [ cookie | piece <- splitOnChar ';' header, let cookie = trimWs piece
  , cookie /= "", trimWs (takeWhile (/= '=') cookie) `notElem` names ]

isJsonMedia :: String -> Bool
isJsonMedia t =
  let media = lowerS (trimWs (takeWhile (/= ';') t))
  in media == "application/json" || media == "text/json" || "+json" `isSuffixOf` media

-- The declared JSON type alone, else every declared type in model order; nothing without a body.
acceptOf :: Value -> IO (Maybe String)
acceptOf point = do
  res <- getp point "response"
  media <- getStrD res "media" ""
  kind <- getStrD res "kind" ""
  altsV <- getp res "alternatives"
  alts <- case altsV of VList _ -> listItems altsV; _ -> pure []
  ms <- mapM (\a -> getStrD a "media" "") alts
  pure (if media == "" then Nothing
        else if kind == "json" then Just media
        else Just (intercalate ", " (media : filter (/= "") ms)))

hasHeader :: Value -> String -> IO Bool
hasHeader headers name = any ((== name) . lowerS) <$> keysof headers

-- A caller's accept wins. A declared request type replaces each JSON
-- content-type, the SDK default, and leaves any other the caller set.
mediaHeaders :: Value -> Value -> IO Value
mediaHeaders point headers = do
  accept <- acceptOf point
  hasAccept <- hasHeader headers "accept"
  case accept of
    Just a | not hasAccept -> setp headers "accept" (VStr a)
    _ -> pure ()
  body <- getp point "body"
  kind <- getStrD body "kind" ""
  media <- getStrD body "media" ""
  when ((kind == "raw" || kind == "json") && media /= "") $ do
    ks <- keysof headers
    forM_ ks $ \k -> when (lowerS k == "content-type") $ do
      v <- getp headers k
      when (isJsonMedia (vstring v)) (delp headers k)
    hasCT <- hasHeader headers "content-type"
    when (not hasCT) (setp headers "content-type" (VStr media))
  pure headers

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

-- A declared header, cookie or query argument of the point: the name it
-- travels under, and the value the call passes in its match or data.
callArgs :: Context -> String -> IO [(String, String, Value)]
callArgs ctx kind = do
  point <- readIORef (cPoint ctx)
  defs <- argDefs point kind
  reqmatch <- readIORef (cReqmatch ctx)
  reqdata <- readIORef (cReqdata ctx)
  fmap concat $ mapM (\ad -> do
    name <- getStrD ad "name" ""
    if name == "" then pure [] else do
      orig <- getStrD ad "orig" ""
      mv <- getp reqmatch name
      val <- if isNullish mv then getp reqdata name else pure mv
      pure [(name, if orig == "" then name else orig, val)]) defs

argDefs :: Value -> String -> IO [Value]
argDefs point kind = do
  args <- getp point "args"
  al <- case args of VMap _ -> getp args kind; _ -> pure VNoval
  case al of VList _ -> listItems al; _ -> pure []

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
  let argNames kind = argDefs point kind >>= mapM (\d -> getStrD d "name" "")

  -- A path parameter travels in the path. The generated config lists them as
  -- args.params, which prepareParams reads; params is the older list of names.
  aparams <- argNames "params"
  let inpath = [s | VStr s <- params] ++ aparams

  -- A query parameter travels under the name the definition gives it, its
  -- orig, which the model may have renamed for the caller.
  qdefs <- argDefs point "query"
  wires <- mapM (\d -> do n <- getStrD d "name" ""; o <- getStrD d "orig" ""; pure (n, o)) qdefs
  let declared = [n | (n, _) <- wires, n /= ""]
      wireOf k = case [o | (n, o) <- wires, n == k, o /= ""] of (o : _) -> o; [] -> k

  -- A header or cookie parameter travels in the headers, which prepareHeaders
  -- fills, unless a query parameter shares its name: then both are sent.
  hnames <- argNames "header"
  cnames <- argNames "cookie"
  let elsewhere = filter (`notElem` declared) (hnames ++ cnames)

  out <- emptyMap
  ks <- keysof reqmatch
  forM_ ks $ \k -> do
    v <- getp reqmatch k
    when (not (isNullish v) && k /= "$action" && k `notElem` inpath && k `notElem` elsewhere)
      (setp out (wireOf k) v)

  -- A create or update passes its query arguments in its data.
  qargs <- callArgs ctx "query"
  forM_ qargs $ \(name, wire, val) ->
    when (not (isNullish val) && name `notElem` inpath) (setp out wire val)
  pure out

prepareBodyUtil :: Context -> IO Value
prepareBodyUtil ctx = do
  op <- readIORef (cOp ctx)
  if opInput op /= "data" then pure VNoval else do
    point <- readIORef (cPoint ctx)
    body <- getp point "body"
    kind <- getStrD body "kind" ""
    if kind == "raw"
      then readIORef (cReqdata ctx) >>= \rd -> getp rd "$body"
      else transformRequestUtil ctx

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
  routed <- routedArgNames ctx
  reqdata <- readIORef (cReqdata ctx) >>= \rd -> omitKeys rd routed
  tr <- toMap <$> getp point "transform"
  out <- case tr of
    VMap _ -> do
      reqform <- getp tr "req"
      case reqform of
        VNoval -> pure reqdata
        _ -> do input <- jo [("reqdata", reqdata)]; transform INone input reqform
    _ -> pure reqdata
  omitKeys out ["$action"]

-- A header, cookie or query argument travels where prepareHeaders or
-- prepareQuery sends it, so the body is built from the request data without it,
-- unless the point marks it as a field the body keeps.
routedArgNames :: Context -> IO [String]
routedArgNames ctx = do
  args <- mapM (callArgs ctx) ["header", "cookie", "query"]
  fields <- fieldArgNames ctx
  pure [name | (name, _, _) <- concat args, name `notElem` fields]

fieldArgNames :: Context -> IO [String]
fieldArgNames ctx = do
  point <- readIORef (cPoint ctx)
  defs <- concat <$> mapM (argDefs point) ["header", "cookie", "query"]
  fmap concat $ mapM (\ad -> do
    name <- getStrD ad "name" ""
    field <- getp ad "field"
    pure [name | isTrueV field]) defs

omitKeys :: Value -> [String] -> IO Value
omitKeys v names = case v of
  VMap _ -> do
    ks <- keysof v
    let hit = filter (`elem` names) ks
    if null hit then pure v else do
      c <- clone v
      forM_ hit (delp c)
      pure c
  _ -> pure v

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
      unr <- getp responseV "unreadable"
      case unr of
        VBool True -> do
          specV <- readIORef (cSpec ctx)
          sent <- case specV of VMap _ -> getp specV "headers"; _ -> pure VNoval
          st <- getp resultV "status"
          hs <- getp resultV "headers"
          prev <- getp resultV "err"
          e <- unreadableBody ctx (toInt st) hs body sent prev
          setp resultV "err" e
        _ -> pure ()
    _ -> pure ()

previewLength :: Int
previewLength = 160

-- A body that is not JSON. An HTTP failure keeps its own error, with the
-- response described; otherwise the code tells a wrong content type from
-- malformed JSON.
unreadableBody :: Context -> Int -> Value -> Value -> Value -> Value -> IO Value
unreadableBody ctx status headers text sent failed = do
  ctype <- headerText headers "content-type"
  agent <- headerText sent "user-agent" >>= cleanText ctx
  preview <- case text of
    VNoval -> pure ""
    VNull -> pure ""
    _ -> (", body: " ++) <$> bodyPreview ctx text
  let detail = "HTTP " ++ show status ++ ", content-type " ++ (if null ctype then "none" else ctype)
        ++ ", user-agent " ++ (if null agent then "transport default" else agent) ++ preview
  isE <- isErr failed
  if isE
    then do
      m <- errMsg failed
      setp failed "message" (VStr (m ++ " (" ++ detail ++ ")"))
      pure failed
    else if null ctype || "json" `isInfixOf` lowerS ctype
      then mkErr "response_json_invalid" ("response: body is not valid JSON (" ++ detail ++ ")")
      else mkErr "response_content_type" ("response: expected JSON, got " ++ ctype ++ " (" ++ detail ++ ")")

headerText :: Value -> String -> IO String
headerText headers name = case headers of
  VMap _ -> do
    ks <- keysof headers
    case filter (\k -> lowerS k == name) ks of
      (k : _) -> getp headers k >>= stringify
      [] -> pure ""
  _ -> pure ""

cleanText :: Context -> String -> IO String
cleanText ctx s = do
  v <- cleanUtil ctx (VStr s)
  pure (case v of VStr c -> c; _ -> s)

-- Cleaned whole: a secret the bound would split could leave its prefix.
bodyPreview :: Context -> Value -> IO String
bodyPreview ctx text = do
  raw <- stringify text
  flat <- cleanText ctx (unwords (words raw))
  pure (if length flat > previewLength then take previewLength flat ++ "..." else flat)

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
      if not (allowListHas av (opName op))
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
      if not (allowListHas amv method)
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
  allow <- jo [("method", VStr "GET,PUT,POST,PATCH,DELETE,OPTIONS"), ("op", VStr "create,update,patch,load,list,remove,command,direct,graphql")]
  entChild <- do a <- emptyMap; jo [("`$OPEN`", VBool True), ("active", VBool False), ("alias", a)]
  ent <- jo [("`$CHILD`", entChild)]
  featChild <- jo [("`$OPEN`", VBool True), ("active", VBool False)]
  feat <- jo [("`$CHILD`", featChild)]
  utilm <- emptyMap
  sysm <- emptyMap
  testEnt <- jo [("`$OPEN`", VBool True)]
  test <- jo [("active", VBool False), ("entity", testEnt)]
  clean <- cleanOptSpec
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
  configV <- readIORef (cConfig ctx)
  config <- case configV of VMap _ -> pure configV; _ -> emptyMap
  cfgoptsV <- toMap <$> getp config "options"
  -- A copy, like optsC: merge writes each merged child back into the map it walks.
  cfgopts <- case cfgoptsV of VMap _ -> clone cfgoptsV; _ -> emptyMap
  -- The secret registry exists BEFORE validation, fed from the raw input, so
  -- the constructor's own rejection of a mistyped credential is clean too.
  cfgclean <- getp cfgopts "clean"
  cfgcleanM <- case cfgclean of VMap _ -> clone cfgclean; _ -> emptyMap
  rawclean <- getp opts0 "clean"
  rawcleanM <- case rawclean of VMap _ -> clone rawclean; _ -> emptyMap
  specclean <- cleanOptSpec
  emc <- emptyMap
  cleanmerged <- merge =<< ja [emc, specclean, cfgcleanM, rawcleanM]
  cleancfg <- makeCleanConfig cleanmerged
  addSensitiveOptions cleancfg ["clean"] opts0
  cvals <- concat <$> mapM (\cl -> case cl of VMap _ -> splitvalues =<< getp cl "values"; _ -> pure [])
                          [cfgclean, rawclean]
  forM_ (map VStr cvals) (cleanAddCfg cleancfg)
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
  optspec <- optSpecValue
  sysFetch <- getpathS opts0 "system.fetch"
  em <- emptyMap
  mlist <- ja [em, cfgopts, opts0]
  merged <- merge mlist
  attempt <- try (validate INone merged optspec) :: IO (Either StructError Value)
  validated <- case attempt of
    Right v -> pure v
    -- The rejection quotes the offending value.
    Left (StructError m) -> do r <- cleanRule cleancfg; throwIO (StructError (cleanStr r m))
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
  derived <- jo [("clean", cleancfg)]
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
  -- Again over the merged result: the config's own defaults can carry one.
  addSensitiveOptions cleancfg ["clean", "__derived__"] opts
  pure opts

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
