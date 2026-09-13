
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'

import { hsVarName } from './utility_haskell'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_haskell'


// test/SdkGenTests.hs — model-driven per-entity tests: an instance test, a
// CRUD basic-flow test driven through the in-memory mock (test mode), and a
// direct() call test against an injected system.fetch mock. Only ops the
// entity actually defines are exercised.
const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const entity = each(entityCollection(model))
    .filter((e: any) => false !== e.active)

  Folder({ name: 'test' }, () => {

    // Structural gate over the documented Haskell examples (emits
    // test/TReadmeExamples.hs); wired into genTests below so it runs in the
    // standard Runner.
    ReadmeExamplesTest({ target })

    File({ name: 'SdkGenTests.' + target.ext }, () => {

      let calls = ''
      let defs = ''

      each(entity, (e: any) => {
        const fn = hsVarName(e.name)
        const ops = Object.keys(e.op || {})
        const hasCreate = ops.includes('create')
        const hasList = ops.includes('list')
        const hasLoad = ops.includes('load')
        const hasUpdate = ops.includes('update')
        const hasRemove = ops.includes('remove')

        // Pick a text field to mutate in update (first non-id field with a
        // string value in the new-ref data, else "name").
        let updField = 'name'
        try {
          const nf = e.fields || {}
          const cand = Object.keys(nf).find((k) => k !== 'id' && !k.endsWith('$'))
          if (cand) updField = cand
        } catch (_e) { }

        const instFn = `${fn}InstanceTest`
        const basicFn = `${fn}BasicTest`
        const directFn = `${fn}DirectTest`

        calls += `  ${instFn} c\n`
        calls += `  ${basicFn} c\n`
        calls += `  ${directFn} c\n`

        defs += `
${instFn} :: Counters -> IO ()
${instFn} c = runTest c "${e.name}.instance" $ do
  sdk <- C.testSdk0
  ent <- C.${fn} sdk VNoval
  pure (eName ent == "${e.name}")

${basicFn} :: Counters -> IO ()
${basicFn} c = do
  fixture <- loadFixture "${e.Name}"
  existing <- getp fixture "existing"
  opts <- jo [("entity", existing)]
`
        // Basic flow. Each op is an independent runTest.
        if (hasList) {
          defs += `  runTest c "${e.name}.list" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    em1 <- emptyMap; em2 <- emptyMap
    lst <- eList ent em1 em2
    -- \`list\` resolves to one ENTITY per record; the record is reached
    -- through eDataGet. See AGENTS.md "Entity operations return ENTITIES".
    ok <- mapM (\\en -> ismap <$> eDataGet en) lst
    pure (all id ok)
`
        }
        if (hasLoad) {
          defs += `  runTest c "${e.name}.load" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    entmap <- getp existing "${e.name}"
    ids <- keysof entmap
    case ids of
      [] -> pure True
      (id0 : _) -> do
        m <- jo [("id", VStr id0)]; ctrl <- emptyMap
        loaded <- eLoad ent m ctrl
        ld <- eDataGet loaded
        lid <- getp ld "id"
        pure (ismap ld && vstring lid == id0)
`
        }
        if (hasCreate) {
          defs += `  runTest c "${e.name}.create" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    d <- newRefData fixture "${e.name}"
    ctrl <- emptyMap
    created <- eCreate ent d ctrl
    cd <- eDataGet created
    cid <- getp cd "id"
    pure (ismap cd && not (isNoval cid))
`
        }
        if (hasCreate && hasUpdate) {
          defs += `  runTest c "${e.name}.update" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    d <- newRefData fixture "${e.name}"
    ctrl <- emptyMap
    created <- eCreate ent d ctrl
    cd <- eDataGet created
    cid <- getp cd "id"
    upd <- jo [("id", cid), ("${updField}", VStr "UpdatedMark")]
    ctrl2 <- emptyMap
    updated <- eUpdate ent upd ctrl2
    ud <- eDataGet updated
    uv <- getp ud "${updField}"
    pure (ismap ud && vstring uv == "UpdatedMark")
`
        }
        if (hasCreate && hasRemove) {
          defs += `  runTest c "${e.name}.remove" $ do
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    d <- newRefData fixture "${e.name}"
    ctrl <- emptyMap
    created <- eCreate ent d ctrl
    cd <- eDataGet created
    cid <- getp cd "id"
    rm <- jo [("id", cid)]; ctrl2 <- emptyMap
    -- \`remove\` resolves to the entity, marked. It KEEPS the data it held.
    removed <- eRemove ent rm ctrl2
    gone <- readIORef (eDeleted removed)
    rd <- eDataGet removed
    rid <- getp rd "id"
    pure (gone && vstring rid == vstring cid)
`
        }
        // An op-less entity (no list/load/create — e.g. a bare path entity)
        // appends no runTest, leaving the do-block ending on `opts <- jo [...]`
        // (a bind), which is illegal as the final statement. Terminate it.
        if (!hasList && !hasLoad && !hasCreate) {
          defs += `  pure ()\n`
        }

        // Direct call test (via injected system.fetch mock).
        defs += `
${directFn} :: Counters -> IO ()
${directFn} c = runTest c "${e.name}.direct" $ do
  calls <- newIORef (0 :: Int)
  let mock = VFunc (\\_ _ _ _ -> do
        modifyIORef calls (+ 1)
        d <- jo [("id", VStr "direct01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk d)])
  sys <- jo [("fetch", mock)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  sdk <- C.newSdk opts
  args <- jo [("path", VStr "/${e.name}/x"), ("method", VStr "GET")]
  res <- F.direct sdk args
  ok <- getp res "ok"
  st <- getp res "status"
  dat <- getp res "data"
  did <- getp dat "id"
  n <- readIORef calls
  pure (isTrueV ok && toInt st == 200 && vstring did == "direct01" && n == 1)
`

        // PR review #4: entity eStream(action, args, callopts) runs the op
        // through the full pipeline and returns a lazy list. Fallback (no
        // streaming feature) yields the materialised items; with the streaming
        // feature active it yields from the streaming iterator (chunkSize
        // groups into batches). Needs a list op; seeds three records.
        if (hasList) {
          const streamFn = `${fn}StreamTest`
          calls += `  ${streamFn} c\n`
          defs += `
${streamFn} :: Counters -> IO ()
${streamFn} c = do
  let mkSeed = do
        r1 <- jo [("id", VStr "S1"), ("name", VStr "a")]
        r2 <- jo [("id", VStr "S2"), ("name", VStr "b")]
        r3 <- jo [("id", VStr "S3"), ("name", VStr "c")]
        recs <- jo [("S1", r1), ("S2", r2), ("S3", r3)]
        jo [("${e.name}", recs)]
      hasStreaming = do
        sdk0 <- C.testSdk0
        fs <- getp (clConfig sdk0) "feature"
        st <- getp fs "streaming"
        pure (not (isNoval st))
  runTest c "${e.name}.stream" $ do
    seed <- mkSeed; opts <- jo [("entity", seed)]
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    em1 <- emptyMap
    items <- eStream ent "list" em1 VNoval
    pure (length items == 3 && (case items of (x : _) -> ismap x; [] -> False))
  runTest c "${e.name}.stream_signal" $ do
    seed <- mkSeed; opts <- jo [("entity", seed)]
    sdk <- C.testSdk opts VNoval
    ent <- C.${fn} sdk VNoval
    em1 <- emptyMap
    n <- newIORef (0 :: Int)
    let sig = vfunc0 (do modifyIORef n (+ 1); v <- readIORef n; pure (VBool (v >= 2)))
    co <- jo [("signal", sig)]
    items <- eStream ent "list" em1 co
    pure (length items == 1)
  runTest c "${e.name}.stream_active" $ do
    hs <- hasStreaming
    if not hs then pure True else do
      seed <- mkSeed; opts <- jo [("entity", seed)]
      stg <- jo [("active", VBool True)]; strm <- jo [("streaming", stg)]; sopts <- jo [("feature", strm)]
      sdk <- C.testSdk opts sopts
      ent <- C.${fn} sdk VNoval
      em1 <- emptyMap
      items <- eStream ent "list" em1 VNoval
      pure (length items == 3)
  runTest c "${e.name}.stream_chunk" $ do
    hs <- hasStreaming
    if not hs then pure True else do
      seed <- mkSeed; opts <- jo [("entity", seed)]
      stg <- jo [("active", VBool True), ("chunkSize", VNum 2)]; strm <- jo [("streaming", stg)]; sopts <- jo [("feature", strm)]
      sdk <- C.testSdk opts sopts
      ent <- C.${fn} sdk VNoval
      em1 <- emptyMap
      batches <- eStream ent "list" em1 VNoval
      pure (length batches == 2)
`
        }
      })

      Content(`-- Generated model-driven entity + direct tests.
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
${calls}${defs}`)
    })
  })
})


export {
  Test
}
