-- Generated model-driven entity + direct tests.
{-# LANGUAGE ScopedTypeVariables #-}

module SdkGenTests (genTests) where

import Control.Exception (SomeException, try)
import Data.IORef

import VoxgigStruct (Value (..), emptyMap, keysof, ismap, islist, isNoval, clone)
import SdkTypes
import SdkHelpers
import qualified SdkFeatures as F
import qualified SdkClient as C
import qualified TReadmeExamples
import Testutil
import SdkJson (jsonRead)

-- Load an entity fixture (../.sdk/test/entity/<name>/<Name>TestData.json).
loadFixture :: String -> IO Value
loadFixture entName = do
  -- The fixture DIRECTORY is the snake_case entity name (create_result), so a
  -- plain lowercase of the CamelCase entName (createresult) misses the
  -- underscores for multi-word entities. Convert CamelCase -> snake_case.
  let lname = camelToSnake entName
  raw <- readFile ("../.sdk/test/entity/" ++ lname ++ "/" ++ entName ++ "TestData.json")
  jsonRead raw
  where
    toLowerCh ch = if ch >= 'A' && ch <= 'Z' then toEnum (fromEnum ch + 32) else ch
    camelToSnake [] = []
    camelToSnake (c0 : rest) = toLowerCh c0 : go rest
    go [] = []
    go (c : cs)
      | c >= 'A' && c <= 'Z' = '_' : toLowerCh c : go cs
      | otherwise = c : go cs

-- The first new-ref data map for an entity (fixture.new.<entity>.<ref0>).
newRefData :: Value -> String -> IO Value
newRefData fixture entName = do
  newEnts <- getpathS fixture ("new." ++ entName)
  refs <- keysof newEnts
  case refs of
    [] -> emptyMap
    (r0 : _) -> do d <- getp newEnts r0; clone d

genTests :: Counters -> IO ()
genTests c = do
  TReadmeExamples.tests c
  convertInstanceTest c
  convertBasicTest c
  convertDirectTest c
  embedInstanceTest c
  embedBasicTest c
  embedDirectTest c
  ephemeral_keyInstanceTest c
  ephemeral_keyBasicTest c
  ephemeral_keyDirectTest c
  modelInstanceTest c
  modelBasicTest c
  modelDirectTest c
  modelStreamTest c

convertInstanceTest :: Counters -> IO ()
convertInstanceTest c = runTest c "convert.instance" $ do
  sdk <- C.testSdk0
  ent <- C.convert sdk VNoval
  pure (eName ent == "convert")

convertBasicTest :: Counters -> IO ()
convertBasicTest c = do
  fixture <- loadFixture "Convert"
  existing <- getp fixture "existing"
  opts <- jo [("entity", existing)]
  runTest c "convert.create" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.convert sdk VNoval
    d <- newRefData fixture "convert"
    ctrl <- emptyMap
    created <- eCreate ent d ctrl
    cd <- eDataGet created
    -- The create RESULT is a map. Deliberately NOT "and it carries an id":
    -- a create response need not return one. univec's convert, embed and
    -- ephemeral_key all answer {success, data:{...}} with no id, so this
    -- target failed three entity tests the go target passes -- go asserts
    -- only that the result is a map, and that is the assertion the model
    -- actually supports.
    pure (ismap cd)

convertDirectTest :: Counters -> IO ()
convertDirectTest c = runTest c "convert.direct" $ do
  calls <- newIORef (0 :: Int)
  let mock = VFunc (\_ _ _ _ -> do
        modifyIORef calls (+ 1)
        d <- jo [("id", VStr "direct01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk d)])
  sys <- jo [("fetch", mock)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  sdk <- C.newSdk opts
  args <- jo [("path", VStr "/convert/x"), ("method", VStr "GET")]
  res <- F.direct sdk args
  ok <- getp res "ok"
  st <- getp res "status"
  dat <- getp res "data"
  did <- getp dat "id"
  n <- readIORef calls
  pure (isTrueV ok && toInt st == 200 && vstring did == "direct01" && n == 1)

embedInstanceTest :: Counters -> IO ()
embedInstanceTest c = runTest c "embed.instance" $ do
  sdk <- C.testSdk0
  ent <- C.embed sdk VNoval
  pure (eName ent == "embed")

embedBasicTest :: Counters -> IO ()
embedBasicTest c = do
  fixture <- loadFixture "Embed"
  existing <- getp fixture "existing"
  opts <- jo [("entity", existing)]
  runTest c "embed.create" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.embed sdk VNoval
    d <- newRefData fixture "embed"
    ctrl <- emptyMap
    created <- eCreate ent d ctrl
    cd <- eDataGet created
    -- The create RESULT is a map. Deliberately NOT "and it carries an id":
    -- a create response need not return one. univec's convert, embed and
    -- ephemeral_key all answer {success, data:{...}} with no id, so this
    -- target failed three entity tests the go target passes -- go asserts
    -- only that the result is a map, and that is the assertion the model
    -- actually supports.
    pure (ismap cd)

embedDirectTest :: Counters -> IO ()
embedDirectTest c = runTest c "embed.direct" $ do
  calls <- newIORef (0 :: Int)
  let mock = VFunc (\_ _ _ _ -> do
        modifyIORef calls (+ 1)
        d <- jo [("id", VStr "direct01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk d)])
  sys <- jo [("fetch", mock)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  sdk <- C.newSdk opts
  args <- jo [("path", VStr "/embed/x"), ("method", VStr "GET")]
  res <- F.direct sdk args
  ok <- getp res "ok"
  st <- getp res "status"
  dat <- getp res "data"
  did <- getp dat "id"
  n <- readIORef calls
  pure (isTrueV ok && toInt st == 200 && vstring did == "direct01" && n == 1)

ephemeral_keyInstanceTest :: Counters -> IO ()
ephemeral_keyInstanceTest c = runTest c "ephemeral_key.instance" $ do
  sdk <- C.testSdk0
  ent <- C.ephemeral_key sdk VNoval
  pure (eName ent == "ephemeral_key")

ephemeral_keyBasicTest :: Counters -> IO ()
ephemeral_keyBasicTest c = do
  fixture <- loadFixture "EphemeralKey"
  existing <- getp fixture "existing"
  opts <- jo [("entity", existing)]
  runTest c "ephemeral_key.create" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.ephemeral_key sdk VNoval
    d <- newRefData fixture "ephemeral_key"
    ctrl <- emptyMap
    created <- eCreate ent d ctrl
    cd <- eDataGet created
    -- The create RESULT is a map. Deliberately NOT "and it carries an id":
    -- a create response need not return one. univec's convert, embed and
    -- ephemeral_key all answer {success, data:{...}} with no id, so this
    -- target failed three entity tests the go target passes -- go asserts
    -- only that the result is a map, and that is the assertion the model
    -- actually supports.
    pure (ismap cd)

ephemeral_keyDirectTest :: Counters -> IO ()
ephemeral_keyDirectTest c = runTest c "ephemeral_key.direct" $ do
  calls <- newIORef (0 :: Int)
  let mock = VFunc (\_ _ _ _ -> do
        modifyIORef calls (+ 1)
        d <- jo [("id", VStr "direct01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk d)])
  sys <- jo [("fetch", mock)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  sdk <- C.newSdk opts
  args <- jo [("path", VStr "/ephemeral_key/x"), ("method", VStr "GET")]
  res <- F.direct sdk args
  ok <- getp res "ok"
  st <- getp res "status"
  dat <- getp res "data"
  did <- getp dat "id"
  n <- readIORef calls
  pure (isTrueV ok && toInt st == 200 && vstring did == "direct01" && n == 1)

modelInstanceTest :: Counters -> IO ()
modelInstanceTest c = runTest c "model.instance" $ do
  sdk <- C.testSdk0
  ent <- C.model sdk VNoval
  pure (eName ent == "model")

modelBasicTest :: Counters -> IO ()
modelBasicTest c = do
  fixture <- loadFixture "Model"
  existing <- getp fixture "existing"
  opts <- jo [("entity", existing)]
  runTest c "model.list" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.model sdk VNoval
    em1 <- emptyMap; em2 <- emptyMap
    lst <- eList ent em1 em2
    -- `list` resolves to one ENTITY per record; the record is reached
    -- through eDataGet. See AGENTS.md "Entity operations return ENTITIES".
    ok <- mapM (\en -> ismap <$> eDataGet en) lst
    -- NOT EMPTY, and then every record a map. `all id` alone is vacuously
    -- true on an empty list, and it was: seeded `list` returned nothing at
    -- all here for as long as the target has existed, and this test passed
    -- throughout. Only `stream`, which counts what it gets, ever failed.
    pure (not (null lst) && all id ok)

modelDirectTest :: Counters -> IO ()
modelDirectTest c = runTest c "model.direct" $ do
  calls <- newIORef (0 :: Int)
  let mock = VFunc (\_ _ _ _ -> do
        modifyIORef calls (+ 1)
        d <- jo [("id", VStr "direct01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk d)])
  sys <- jo [("fetch", mock)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  sdk <- C.newSdk opts
  args <- jo [("path", VStr "/model/x"), ("method", VStr "GET")]
  res <- F.direct sdk args
  ok <- getp res "ok"
  st <- getp res "status"
  dat <- getp res "data"
  did <- getp dat "id"
  n <- readIORef calls
  pure (isTrueV ok && toInt st == 200 && vstring did == "direct01" && n == 1)

modelStreamTest :: Counters -> IO ()
modelStreamTest c = do
  let mkSeed = do
        r1 <- jo [("id", VStr "S1"), ("name", VStr "a")]
        r2 <- jo [("id", VStr "S2"), ("name", VStr "b")]
        r3 <- jo [("id", VStr "S3"), ("name", VStr "c")]
        recs <- jo [("S1", r1), ("S2", r2), ("S3", r3)]
        jo [("model", recs)]
      hasStreaming = do
        sdk0 <- C.testSdk0
        fs <- getp (clConfig sdk0) "feature"
        st <- getp fs "streaming"
        pure (not (isNoval st))
  runTest c "model.stream" $ do
    seed <- mkSeed; opts <- jo [("entity", seed)]
    sdk <- C.testSdk opts VNoval
    ent <- C.model sdk VNoval
    em1 <- emptyMap
    items <- eStream ent "list" em1 VNoval
    pure (length items == 3 && (case items of (x : _) -> ismap x; [] -> False))
  runTest c "model.stream_signal" $ do
    seed <- mkSeed; opts <- jo [("entity", seed)]
    sdk <- C.testSdk opts VNoval
    ent <- C.model sdk VNoval
    em1 <- emptyMap
    n <- newIORef (0 :: Int)
    let sig = vfunc0 (do modifyIORef n (+ 1); v <- readIORef n; pure (VBool (v >= 2)))
    co <- jo [("signal", sig)]
    items <- eStream ent "list" em1 co
    pure (length items == 1)
  runTest c "model.stream_active" $ do
    hs <- hasStreaming
    if not hs then pure True else do
      seed <- mkSeed; opts <- jo [("entity", seed)]
      stg <- jo [("active", VBool True)]; strm <- jo [("streaming", stg)]; sopts <- jo [("feature", strm)]
      sdk <- C.testSdk opts sopts
      ent <- C.model sdk VNoval
      em1 <- emptyMap
      items <- eStream ent "list" em1 VNoval
      pure (length items == 3)
  runTest c "model.stream_chunk" $ do
    hs <- hasStreaming
    if not hs then pure True else do
      seed <- mkSeed; opts <- jo [("entity", seed)]
      stg <- jo [("active", VBool True), ("chunkSize", VNum 2)]; strm <- jo [("streaming", stg)]; sopts <- jo [("feature", strm)]
      sdk <- C.testSdk opts sopts
      ent <- C.model sdk VNoval
      em1 <- emptyMap
      batches <- eStream ent "list" em1 VNoval
      pure (length batches == 2)
