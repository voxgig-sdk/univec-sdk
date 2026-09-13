-- Univec SDK primary-utility corpus.
--
-- Drives the SHARED language-neutral corpus (../.sdk/test/test.json ->
-- "primary") through this SDK's request-shaping utilities, so the cases
-- cannot drift from the reference implementation. Each section is looked up
-- by name and executed on the VENDORED @voxgig/omni engine through
-- OmniResolver, exactly as the ts/js reference harness does.
--
-- This is what makes the target FULL tier. `TPrimaryUtility` remains beside
-- it: its hand-written cases cover utilities the 22 corpus sections do not
-- reach (featureAdd/featureHook/featureInit, fetcher, clean), and deleting
-- them to "replace with the corpus" would lose coverage rather than gain it.
--
-- Every section uses `runsetArgs`: a `ctx` entry arrives as the first
-- argument, a MAP, which the call site turns into a LIVE Context, runs the
-- utility on, and writes the observable state back into — which is what makes
-- `match: {ctx: ...}` (retargeted onto `match: {args: {"0": ...}}` by the
-- resolver, decision 3) read the POST-call state rather than a stale
-- pre-call copy.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TPrimaryCorpus (tests) where

import Control.Exception (try)
import Control.Monad (forM_, when)
import Data.Char (toLower)
import Data.IORef

import qualified Omni as O
import OmniResolver

import VoxgigStruct (Value (..), emptyMap, ismap, isNoval, keysof, mkList)
import SdkTypes
import SdkHelpers
import SdkRuntime
import qualified SdkClient as C
import Testutil


-- A client built from a section's DEF.setup.a block. prepareAuth reads the
-- CLIENT's options, as the ts reference does via client.options(), so a
-- section's setup cannot reach it through ctx.options.
clientFor :: Runner -> String -> IO Client
clientFor r name = do
  let setup = O.getpath (runnerSpec r) [name, "DEF", "setup", "a"]
  if O.ismap setup
    -- `testSdk testopts sdkopts` — a section's setup block is SDK options
    -- (base/prefix/suffix), so it is the SECOND argument. Passing it as the
    -- first made it test options, which makeSpec never reads: every base,
    -- prefix and suffix came out empty.
    then do sv <- tostruct setup; C.testSdk VNoval sv
    else C.testSdk0


-- A LIVE Context from a corpus map. This port stores spec, result and
-- response as plain `IORef Value`, so the corpus's maps go straight in —
-- no typed-record construction, unlike the ocaml and rust peers.
ctxFrom :: Client -> Value -> IO Context
ctxFrom cl ctxmap = do
  -- The corpus names the op — {"ctx": {"opname": "create"}} — and
  -- prepareMethod reads it. Hardcoding "load" made every method GET, and
  -- defaulting to it made the SDK report the wrong operation where the
  -- corpus expects "unknown operation".
  opname <- getp ctxmap "opname"
  let cs = case opname of
        VStr s -> defaultCtxSpec { csOpname = Just s, csClient = Just cl
                                 , csUtility = Just (clUtility cl) }
        _ -> defaultCtxSpec { csClient = Just cl, csUtility = Just (clUtility cl) }
  root <- readIORef (clRootctx cl)
  ctx <- makeContextImpl cs root

  let put ref key = do
        v <- getp ctxmap key
        when (not (isNoval v)) (writeIORef ref v)

  put (cSpec ctx) "spec"
  put (cResult ctx) "result"

  -- The corpus writes `result.err` as a plain {"message": ...}, but `isErr`
  -- recognises an error by its `__sdkerr__` marker — so resultBasic saw no
  -- previous error and dropped the message it must PREPEND ("Foo: request:
  -- 400: BAD" came out as "request: 400: BAD"). Rebuild it as a real error.
  -- The ocaml and lua drivers do the same for the same reason.
  resv <- readIORef (cResult ctx)
  when (ismap resv) $ do
    err <- getp resv "err"
    when (ismap err) $ do
      m <- getp err "message"
      case m of
        VStr msg | not (null msg) -> do e <- mkErr "" msg; setp resv "err" e
        _ -> pure ()
  put (cPoint ctx) "point"
  put (cReqdata ctx) "reqdata"
  put (cReqmatch ctx) "reqmatch"
  put (cData ctx) "data"
  put (cMatch ctx) "match"
  put (cConfig ctx) "config"
  put (cOptions ctx) "options"

  response <- getp ctxmap "response"
  when (ismap response) $ do
    -- resultBodyUtil reads response.json and requires it to be CALLABLE;
    -- the corpus supplies a plain `body`, so wrap it, as the ocaml, lua and
    -- elixir drivers do. Without this every ctx.result.body match reads empty.
    body <- getp response "body"
    when (not (isNoval body)) $
      setp response "json" (VFunc (\_ _ _ _ -> pure body))
    -- Header names arrive from the wire in any case and the contract is
    -- lowercase; resultHeadersUtil copies them verbatim, so normalise here
    -- rather than in the utility, as the other drivers do.
    hdrs <- getp response "headers"
    when (ismap hdrs) $ do
      low <- emptyMap
      ks <- keysof hdrs
      forM_ ks $ \k -> do v <- getp hdrs k; setp low (map toLower k) v
      setp response "headers" low
    writeIORef (cResponse ctx) response

  pure ctx


-- Publish the MUTATED state back onto the corpus map the match reads. The
-- resolver retargets `match: {ctx: ...}` onto `match: {args: {"0": ...}}` and
-- writes the argument array back after the call, so this map IS what the
-- assertions read — but only for the state written here.
publish :: Value -> Context -> IO ()
publish ctxmap ctx = do
  sp <- readIORef (cSpec ctx)
  when (not (isNoval sp)) (setp ctxmap "spec" sp)
  rs <- readIORef (cResult ctx)
  when (not (isNoval rs)) (setp ctxmap "result" rs)
  rp <- readIORef (cResponse ctx)
  when (not (isNoval rp)) (setp ctxmap "response" (VStr O.existsmark))


-- A `UResult` utility reports its error in the second component. Raise it, so
-- omni sees a subject failure and an `err` entry can match on the message;
-- returning it as data would make every error case read as a pass.
ures :: UResult -> IO Value
ures act = do
  (v, merr) <- act
  case merr of
    Just e | not (isNoval e) -> do
      msg <- getp e "message"
      case msg of
        VStr m -> errorWithoutStackTrace m
        _ -> pure v
    _ -> pure v


-- The SDK raises `SdkException`, whose `Show` instance is the constant
-- "DemoSDK error" — the message lives in the wrapped value. omni renders an
-- unknown exception through `displayException`, so without this every `err`
-- entry matched against that constant instead of the real message. Translated
-- HERE, not in OmniResolver, because this is where `SdkTypes` is in scope.
guarded :: IO Value -> IO Value
guarded act = do
  r <- try act
  case r of
    Right v -> pure v
    Left (SdkException ev) -> do
      m <- errMsg ev
      errorWithoutStackTrace m


arg :: [Value] -> Int -> Value
arg vs i = if i < length vs then vs !! i else VNoval


tests :: Counters -> Value -> IO ()
tests c alltests = do
  jalltests <- toomni alltests
  r <- newRunner jalltests "primary"

  cl <- C.testSdk0

  -- Sections whose first argument IS the ctx map.
  -- Every section goes through `guarded`: the bare-args ones raise the same
  -- branded exception as the ctx ones, and makeError raises it BY DESIGN.
  let runsetVals name f = runsetArgs r name (guarded . f)
      runsetCtxWith cl2 name f =
        runsetArgs r name $ \args -> do
          let ctxmap = arg args 0
          ctx <- ctxFrom cl2 ctxmap
          out <- guarded (f ctx)
          publish ctxmap ctx
          pure out
      runsetCtx name f = runsetCtxWith cl name f

  runsetCtx "done" doneUtil
  runsetCtx "makeUrl" (\ctx -> ures (makeUrlUtil ctx))
  runsetCtx "makeRequest" (\ctx -> ures (makeRequestUtil ctx) >> readIORef (cResult ctx))
  runsetCtx "makeResponse" (\ctx -> ures (makeResponseUtil ctx) >> readIORef (cResult ctx))
  runsetCtx "prepareBody" prepareBodyUtil
  runsetCtx "prepareHeaders" prepareHeadersUtil
  runsetCtx "prepareMethod" (\ctx -> do
    m <- prepareMethodUtil ctx
    pure (if null m then VNoval else VStr m))
  runsetCtx "prepareParams" prepareParamsUtil
  runsetCtx "preparePath" (\ctx -> VStr <$> preparePathUtil ctx)
  runsetCtx "prepareQuery" prepareQueryUtil
  runsetCtx "resultBasic" (\ctx -> resultBasicUtil ctx >> readIORef (cResult ctx))
  runsetCtx "resultBody" (\ctx -> resultBodyUtil ctx >> readIORef (cResult ctx))
  runsetCtx "resultHeaders" (\ctx -> resultHeadersUtil ctx >> readIORef (cResult ctx))
  runsetCtx "transformRequest" transformRequestUtil
  runsetCtx "transformResponse" transformResponseUtil

  -- Sections configured by their own DEF.setup block get their own client.
  clSpec <- clientFor r "makeSpec"
  runsetCtxWith clSpec "makeSpec" (\ctx -> ures (makeSpecUtil ctx))
  clAuth <- clientFor r "prepareAuth"
  runsetCtxWith clAuth "prepareAuth"
    (\ctx -> ures (prepareAuthUtil ctx) >> readIORef (cSpec ctx))

  -- Sections that take a bare map or explicit args rather than a ctx.
  runsetVals "makeContext" $ \args -> do
    ctx <- ctxFrom cl (arg args 0)
    op <- readIORef (cOp ctx)
    inner <- jo [ ("entity", VStr (opEntity op)), ("name", VStr (opName op))
                , ("input", VStr (opInput op)), ("points", opPoints op) ]
    jo [("op", inner)]

  runsetVals "makeOptions" $ \args -> do
    let inv = arg args 0
    em <- emptyMap
    ctx <- ctxFrom cl em
    cfg <- getp inv "config"; writeIORef (cConfig ctx) cfg
    opt <- getp inv "options"; writeIORef (cOptions ctx) opt
    makeOptionsUtil ctx

  runsetVals "makeError" $ \args -> do
    let a0 = arg args 0
    ctx <- ctxFrom cl a0
    msg <- getp (arg args 1) "message"
    out <- case msg of
      VStr m | not (null m) -> do
        e <- jo [("message", VStr m)]
        makeErrorUtil ctx (Just e)
      _ -> makeErrorUtil ctx Nothing
    publish a0 ctx
    pure out

  runsetVals "operator" $ \args -> do
    op <- newOperation (arg args 0)
    jo [ ("entity", VStr (opEntity op)), ("input", VStr (opInput op))
       , ("name", VStr (opName op)), ("points", opPoints op) ]

  runsetVals "param" $ \args -> do
    let a0 = arg args 0
    ctx <- ctxFrom cl a0
    out <- paramUtil ctx (arg args 1)
    publish a0 ctx
    pure out

  -- One counter entry per section, so a regression names the section.
  p <- runnerPass r
  f <- runnerFail r
  msgs <- runnerFailures r
  forM_ msgs (recordFail c)
  forM_ [1 .. p] (\_ -> recordPass c)
  when (f /= length msgs) (recordFail c "primary corpus: counter mismatch")
