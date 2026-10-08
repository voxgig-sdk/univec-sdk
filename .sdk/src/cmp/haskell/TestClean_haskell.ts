
import {
  cmp,
  each,
  File,
  Content,
  entityCollection,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'

import { hsVarName } from './utility_haskell'


// The canary sweep (port of the ts TestClean component): canaries in every
// credential slot, every diagnostic feature capturing into a sink, a real
// operation through every outcome, and every emitted string searched for the
// canaries and their encoded forms. The client has no reflection, so the
// candidate operations are listed at generation time.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  const rank: Record<string, number> = { list: 0, load: 1 }
  const candidates: string[] = []
  each(entityCollection(model))
    .filter((e: any) => false !== e.active)
    .forEach((ent: any) => {
      const fn = hsVarName(ent.name)
      const ops = Object.keys(ent.op || {})
        .filter((op) => ['list', 'load', 'create', 'update', 'patch', 'remove'].includes(op))
        .sort((a, b) => (rank[a] ?? 2) - (rank[b] ?? 2))
      for (const op of ops) {
        const call = 'list' === op
          ? `es <- eList ent m ctrl; pure (vint (length es))`
          : `en <- e${op.charAt(0).toUpperCase() + op.slice(1)} ent m ctrl; eDataGet en`
        const params = pointParams(ent.op[op]).map((p) => JSON.stringify(p)).join(', ')
        candidates.push(
          `  , Candidate "${ent.name}.${op}" [${params}]\n` +
          `      (\\sdk m ctrl -> do ent <- C.${fn} sdk VNoval; ${call})\n` +
          `      (\\sdk m co -> do ent <- C.${fn} sdk VNoval; eStream ent "${op}" m co)`)
      }
    })

  File({ name: 'TClean.' + target.ext }, () => Content(render(auth, candidates)))
})


// Every path parameter an operation's points declare, as the generated
// config carries them (point.args.params[].name).
function pointParams(op: any): string[] {
  const vals = (x: any): any[] => null == x ? [] : Array.isArray(x) ? x : Object.values(x)
  const names: string[] = []
  for (const pt of vals(op?.points)) {
    if (null == pt || false === pt.a) continue
    for (const p of vals(pt.g?.params)) {
      if (null != p && false !== p.a && 'string' === typeof p.n && !names.includes(p.n)) {
        names.push(p.n)
      }
    }
  }
  return names
}


function render(
  auth: { suppressed: boolean, where: string, name: string, basic: boolean },
  candidates: string[],
): string {
  return `-- Generated secret-redaction sweep. Every credential slot holds a canary,
-- every diagnostic feature this SDK carries captures into a sink, a real
-- operation runs through every outcome, and every string that leaves the SDK
-- is searched for the canaries and their encoded forms. The second action
-- switches clean off and requires the canary to show, so a sweep that cannot
-- see a leak fails rather than passing.
{-# LANGUAGE ScopedTypeVariables #-}

module TClean (tests) where

import Control.Exception (SomeException, displayException, fromException, try)
import Control.Monad (forM, forM_, when)
import Data.Either (isLeft)
import Data.IORef
import Data.List (intercalate, isInfixOf, isSuffixOf)
import Data.Maybe (isJust)

import VoxgigStruct (Value (..), emptyMap, keysof, listItems, ismap, stringify, vint)
import SdkTypes
import SdkHelpers
import SdkRuntime (base64Encode, escurlS, contextToValue)
import qualified SdkClient as C
import qualified SdkFeatures as F
import Harness (hasFeature)
import Testutil

-- Generated: the credential's wire placement is fixed when the SDK is built.
-- The haskell runtime carries the credential in the Authorization header
-- whatever the model's placement says (its prepareAuth is header-only, and
-- the option spec has no Basic \`secret\`), so that is the slot asserted.
-- Placement: ${auth.where} (${auth.name}), basic: ${auth.basic}.
authSuppressed :: Bool
authSuppressed = ${auth.suppressed ? 'True' : 'False'}

canaryApikey, canaryHeader, canaryValue, mask :: String
canaryApikey = "CANARY-APIKEY-k9x2m7q4p1"
canaryHeader = "CANARY-HEADER-z1x4c7v0b3"
canaryValue = "CANARY-VALUE-n5m8b2v9c4"
mask = "[redacted]"

-- Every form a canary can travel in.
forms :: IO [String]
forms = do
  encs <- forM [canaryApikey, canaryHeader, canaryValue] $ \\v -> do
    pe <- escurlS v
    pure [v, base64Encode v, pe]
  pure (concat encs)

type Sinks = IORef [(String, String)]

push :: Sinks -> String -> String -> IO ()
push sinks name text = modifyIORef sinks (++ [(name, text)])

pushValue :: Sinks -> String -> Value -> IO ()
pushValue sinks name v = do
  j <- jsonifyCompact v
  push sinks (name ++ ":json") j
  s <- stringify v
  push sinks (name ++ ":string") s

-- Header maps keep the caller's spelling; the assertion should not care.
headerOf :: Value -> String -> IO String
headerOf m name = do
  v <- case m of VMap _ -> headerCI m name; _ -> pure VNoval
  pure (vstring v)

leaksIn :: [String] -> String -> [String]
leaksIn fs text = filter (\`isInfixOf\` text) fs

-- Transport-shaped response; \`json\` is the thunk the result stage calls.
response :: Int -> Value -> [(String, String)] -> IO Value
response status dat headers = do
  h <- jo (("content-type", VStr "application/json") : [(k, VStr v) | (k, v) <- headers])
  jo [ ("status", vint status), ("statusText", VStr (if status < 400 then "OK" else "ERR"))
     , ("headers", h), ("body", VStr "body"), ("json", jsonThunk dat) ]

data Scenario = Scenario { scName :: String, scRespond :: String -> IO Value }

scenarios :: [Scenario]
scenarios =
  [ Scenario "ok" (\\_ -> do
      d <- jo [("id", VStr "i1"), ("name", VStr "n1")]
      response 200 d [("x-session-token", "RESP-TOKEN-a1b2c3d4e5")])
  , Scenario "notfound" (\\_ -> do d <- jo [("error", VStr "no such record")]; response 404 d [])
  , Scenario "server" (\\_ -> do d <- jo [("error", VStr "boom")]; response 500 d [])
  -- The transport's failure is the map the system.fetch contract reserves
  -- for it, quoting the URL as a client library would.
  , Scenario "transport" (\\url -> jo [("__err__", VStr ("socket hang up (URL was: \\"" ++ url ++ "\\")"))])
  , Scenario "notjson" (\\_ -> do
      h <- emptyMap
      jo [ ("status", vint 200), ("statusText", VStr "OK"), ("headers", h)
         , ("body", VStr "<html>"), ("json", jsonThunk (VStr "<html>")) ])
  , thrown
  ]

-- A system.fetch that throws instead, as a client library does, quoting the key.
thrown :: Scenario
thrown = Scenario "thrown" (\\url ->
  ioError (userError ("refused " ++ canaryApikey ++ " (URL was: \\"" ++ url ++ "\\")")))

-- A 200 whose body is not JSON: the parser fails, quoting what it read.
unparsed :: Scenario
unparsed = Scenario "unparsed" (\\_ -> do
  h <- emptyMap
  jo [ ("status", vint 200), ("statusText", VStr "OK"), ("headers", h), ("body", VStr "<html>")
     , ("json", vfunc1 (\\_ -> ioError (userError ("Unexpected token < in JSON: " ++ canaryApikey)))) ])

hookFeature :: String -> (String -> Context -> IO ()) -> IO Feature
hookFeature name hook = do
  active <- newIORef True
  fopts <- newIORef VNoval
  pure Feature { fName = name, fVersion = "0.0.1", fActive = active
               , fOptions = fopts, fInit = \\_ _ -> pure (), fHook = hook }

-- Nothing builds the client with no clean block at all, as most callers do.
makeSdk :: Scenario -> Sinks -> Maybe [(String, Value)] -> [Feature] -> IO Client
makeSdk sc sinks cleanopts extras = do
  let capture name = vfunc1 (\\rec -> do pushValue sinks name rec; pure VNoval)
  feature <- emptyMap
  let addFeature fname extra = do
        present <- hasFeature fname
        when present $ do fo <- jo (("active", VBool True) : extra); setp feature fname fo
  addFeature "log" [("logger", capture "log")]
  addFeature "debug" [("onEntry", capture "debug")]
  addFeature "audit" [("sink", capture "audit")]
  addFeature "telemetry" [("exporter", capture "telemetry")]
  addFeature "metrics" []
  addFeature "clienttrack" []
  clean <- mapM (\\more -> jo (("values", VStr canaryValue) : more)) cleanopts
  headers <- jo [("X-Custom-Token", VStr canaryHeader)]
  let fetch = vfunc1 (\\args -> do
        its <- listItems args
        scRespond sc (case its of (u : _) -> vstring u; [] -> ""))
  sys <- jo [("fetch", fetch)]
  opts <- jo ([ ("apikey", VStr canaryApikey), ("headers", headers)
              , ("feature", feature), ("system", sys) ] ++ [("clean", cl) | Just cl <- [clean]])
  sdk <- C.newSdk opts
  -- Captures the serialised context from inside the pipeline: what a hook
  -- author would hand to a logger.
  capFeature <- hookFeature "capture" (\\name ctx ->
    when (name \`elem\` ["PreRequest", "PreResponse", "PreUnexpected"]) $ do
      cv <- contextToValue ctx
      pushValue sinks ("ctx@" ++ name) cv)
  modifyIORef (clFeatures sdk) (++ (capFeature : extras))
  pure sdk

-- A feature that throws from inside the pipeline at the named stages,
-- quoting the request it saw: an error makeError never handled.
throwFeature :: [String] -> IO Feature
throwFeature stages = hookFeature "throwhook" (\\name ctx ->
  when (name \`elem\` stages) $ do
    sp <- readIORef (cSpec ctx)
    j <- case sp of VMap _ -> jsonifyCompact sp; _ -> pure ""
    ioError (userError ("hook saw " ++ j)))

-- A stream that fails while the caller iterates it, quoting a credential.
streamThrowFeature :: IO Feature
streamThrowFeature = hookFeature "streamthrow" (\\name ctx ->
  when (name == "PreDone") $ do
    rv <- readIORef (cResult ctx)
    when (ismap rv) $
      setp rv "stream" (vfunc1 (\\_ -> ioError (userError ("stream saw " ++ canaryApikey)))))

-- A stream that succeeds, yielding the result's items.
streamOkFeature :: IO Feature
streamOkFeature = hookFeature "streamok" (\\name ctx ->
  when (name == "PreDone") $ do
    rv <- readIORef (cResult ctx)
    when (ismap rv) $ do
      rd <- getp rv "resdata"
      items <- case rd of VList _ -> pure rd; VNoval -> ja []; v -> ja [v]
      setp rv "stream" (vfunc1 (\\_ -> pure items)))

data Candidate = Candidate
  { cdName :: String, cdParams :: [String], cdRun :: Client -> Value -> Value -> IO Value
  , cdStream :: Client -> Value -> Value -> IO [Value] }

-- An operation and the match it completes with.
type Target = (Candidate, [(String, Value)])

-- Every entity operation this SDK offers, list and load first.
candidates :: [Candidate]
candidates =
  [ Candidate "_.none" [] (\\_ _ _ -> ioError (userError "no candidate"))
      (\\_ _ _ -> ioError (userError "no candidate"))
${candidates.join('\n')}
  ]

-- The first operation that completes against a plain 200: with no
-- arguments, else with every path parameter its points declare filled in.
usableOp :: IO (Maybe Target)
usableOp = go [(c, m) | c <- drop 1 candidates, m <- [[], [(p, VStr "p1") | p <- cdParams c]]]
  where
    go [] = pure Nothing
    go ((c, m) : rest) = do
      d <- jo [("id", VStr "i1")]
      let fetch = vfunc1 (\\_ -> response 200 d [])
      sys <- jo [("fetch", fetch)]
      opts <- jo [("apikey", VStr canaryApikey), ("system", sys)]
      sdk <- C.newSdk opts
      ctrl <- emptyMap
      mv <- jo m
      r <- try (cdRun c sdk mv ctrl) :: IO (Either SomeException Value)
      case r of
        Right _ -> pure (Just (c, m))
        Left _ -> go rest

-- Every surface of a caught exception: its print and, for the SDK's own
-- error, the value it carries.
pushException :: Sinks -> String -> SomeException -> IO Value
pushException sinks name e = do
  push sinks (name ++ ":show") (show e)
  push sinks (name ++ ":display") (displayException e)
  case fromException e of
    Just (SdkException ev) -> do pushValue sinks name ev; pure ev
    Nothing -> jo [("message", VStr (show e))]

sameNode :: Value -> Value -> Bool
sameNode (VMap a) (VMap b) = a == b
sameNode _ _ = False

drive :: Client -> Target -> Value -> Sinks -> IO (Maybe Value)
drive sdk (c, m) ctrl sinks = do
  -- A caller may keep the record it passed rather than read ctrl.explain.
  held <- getp ctrl "explain"
  mv <- jo m
  r <- try (cdRun c sdk mv ctrl) :: IO (Either SomeException Value)
  err <- case r of
    Right out -> do pushValue sinks "result" out; pure Nothing
    Left e -> Just <$> pushException sinks "error" e
  ex <- getp ctrl "explain"
  case ex of VMap _ -> pushValue sinks "explain" ex; _ -> pure ()
  when (ismap held && not (sameNode held ex)) (pushValue sinks "explain:held" held)
  pure err

variants :: [(String, IO Value)]
variants =
  [ ("throw", emptyMap)
  , ("explain", do ex <- emptyMap; jo [("explain", ex)])
  , ("nothrow", do ex <- emptyMap; jo [("throw", VBool False), ("explain", ex)]) ]

-- The harness has no skip, so an unusable SDK says so and records nothing.
skipLine :: String
skipLine = "SKIP clean: no operation of this SDK completes against a plain 200; nothing to sweep"

tests :: Counters -> IO ()
tests c = do
  runAction c "clean.sweep" $ do
    mtarget <- usableOp
    case mtarget of
      Nothing -> putStrLn skipLine
      Just target -> do
        sinks <- newIORef []
        errors <- newIORef ([] :: [(String, Value)])
        explains <- newIORef ([] :: [(String, Value)])
        forM_ scenarios $ \\sc -> forM_ variants $ \\(vname, mkCtrl) -> do
          sdk <- makeSdk sc sinks (Just []) []
          ctrl <- mkCtrl
          merr <- drive sdk target ctrl sinks
          let key = scName sc ++ "/" ++ vname
          case merr of Just e -> modifyIORef errors (++ [(key, e)]); Nothing -> pure ()
          ex <- getp ctrl "explain"
          case ex of VMap _ -> modifyIORef explains (++ [(key, ex)]); _ -> pure ()
          -- The client record has no Show instance and no serialiser, so it
          -- has no default print to sweep.

        -- A credential mistyped as a map is rejected by validation, whose
        -- message quotes the value it rejected; with and without a clean block.
        forM_ [True, False] $ \\withClean -> do
          mistyped <- jo [("value", VStr canaryApikey)]
          mclean <- jo [("values", VStr canaryValue)]
          mopts <- jo (("apikey", mistyped) : [("clean", mclean) | withClean])
          rejected <- try (C.newSdk mopts) :: IO (Either SomeException Client)
          case rejected of
            Left e -> do _ <- pushException sinks "rejected" e; pure ()
            Right _ -> check c "clean.mistyped_credential_rejected" False

        -- An error a feature hook throws, quoting the request, skips makeError,
        -- and so does the explain record it leaves behind. This catch path fires
        -- no PreUnexpected, so the 404 reaches that hook through makeError.
        forM_ [ (scenarios !! 0, ["PreResponse"]), (scenarios !! 0, ["PreResponse", "PreUnexpected"])
              , (scenarios !! 1, ["PreUnexpected"]) ] $ \\(sc, stages) -> do
          thrower <- throwFeature stages
          hooked <- makeSdk sc sinks (Just []) [thrower]
          hctrl <- do ex <- emptyMap; jo [("explain", ex)]
          hookerr <- drive hooked target hctrl sinks
          hookmsg <- maybe (pure "") (\\e -> getStrD e "message" "") hookerr
          check c ("clean.throwing_hook_fails_the_op " ++ unwords stages) ("hook saw" \`isInfixOf\` hookmsg)

        -- Iterating a stream runs inside the same catch path as the operation,
        -- and the explain record the caller passed is cleaned however it ends.
        forM_ [("stream", [streamThrowFeature]), ("stream-ok", [streamOkFeature]), ("stream-plain", [])] $
          \\(name, mkFeatures) -> do
            extra <- sequence mkFeatures
            streamed <- makeSdk (scenarios !! 0) sinks (Just []) extra
            smatch <- jo (snd target)
            explain <- emptyMap
            sctrl <- jo [("explain", explain)]
            callopts <- jo [("ctrl", sctrl)]
            streamerr <- try (cdStream (fst target) streamed smatch callopts) :: IO (Either SomeException [Value])
            either (\\e -> () <$ pushException sinks name e) (const (pure ())) streamerr
            check c ("clean." ++ name ++ " throws only when it fails") ((name == "stream") == isLeft streamerr)
            filled <- keysof explain
            check c ("clean." ++ name ++ " fills the explain record") (not (null filled))
            pushValue sinks (name ++ ":explain") explain

        -- Most callers pass no clean block; the defaults alone must mask.
        forM_ [scenarios !! 1, scenarios !! 3] $ \\sc -> do
          bare <- makeSdk sc sinks Nothing []
          bctrl <- do ex <- emptyMap; jo [("explain", ex)]
          drive bare target bctrl sinks

        -- The raw path returns its failure rather than throwing it. The key
        -- rides in the query, as a caller of an endpoint wanting it there sends it.
        rawSdk <- makeSdk (scenarios !! 3) sinks (Just []) []
        rawQuery <- jo [("api_key", VStr canaryApikey)]
        raw <- F.direct rawSdk =<< jo [("path", VStr "raw"), ("query", rawQuery)]
        rawOk <- getp raw "ok"
        rawErr <- getp raw "err"
        check c "clean.direct_transport_fails" (not (isTrueV rawOk) && ismap rawErr)
        pushValue sinks "direct" rawErr

        -- A system.fetch that throws fails direct() the same way.
        thrownSdk <- makeSdk thrown sinks (Just []) []
        rawThrown <- try (F.direct thrownSdk =<< jo [("path", VStr "raw")]) :: IO (Either SomeException Value)
        thrownFails <- case rawThrown of
          Left e -> False <$ pushException sinks "direct-thrown" e
          Right res -> do
            tErr <- getp res "err"
            pushValue sinks "direct-thrown" tErr
            tOk <- getp res "ok"
            pure (not (isTrueV tOk) && ismap tErr)
        check c "clean.direct_thrown_fetch_fails" thrownFails

        -- A body that does not parse fails nothing: data stays unset and ok
        -- follows the status, as the ts direct() does.
        unparsedSdk <- makeSdk unparsed sinks (Just []) []
        rawUnparsed <- try (F.direct unparsedSdk =<< jo [("path", VStr "raw")]) :: IO (Either SomeException Value)
        unparsedOk <- case rawUnparsed of
          Left e -> False <$ pushException sinks "direct-unparsed" e
          Right res -> do
            pushValue sinks "direct-unparsed" res
            let absent v = case v of VNoval -> True; VNull -> True; _ -> False
            uOk <- getp res "ok"; uData <- getp res "data"; uErr <- getp res "err"
            pure (isTrueV uOk && absent uData && absent uErr)
        check c "clean.direct_unparsed_body_is_ok" unparsedOk

        fs <- forms
        swept <- readIORef sinks
        let leaked = [(n, found) | (n, t) <- swept, let found = leaksIn fs t, not (null found)]
        putStrLn ("clean: swept " ++ show (length swept) ++ " surface(s), " ++ show (length leaked) ++ " leak(s)")
        forM_ leaked $ \\(n, found) -> putStrLn ("  leak: " ++ n ++ " [" ++ intercalate ", " found ++ "]")
        check c "clean.no_leak" (null leaked)

        -- The positive half: the slot the credential travelled in is masked,
        -- and an unregistered token in a response header is masked by name.
        errs <- readIORef errors
        exps <- readIORef explains
        check c "clean.404_throws" (isJust (lookup "notfound/throw" errs))
        check c "clean.thrown_fetch_fails_the_op" (isJust (lookup "thrown/throw" errs))
        notfound <- maybe emptyMap pure (lookup "notfound/throw" errs)
        nfResult <- getp notfound "result"
        st <- case nfResult of VMap _ -> getp nfResult "status"; _ -> pure VNoval
        check c "clean.404_status" (toInt st == 404)
        nfSpec <- getp notfound "spec"
        nfHeaders <- case nfSpec of VMap _ -> getp nfSpec "headers"; _ -> pure VNoval
        auth <- headerOf nfHeaders "authorization"
        check c "clean.credential_slot_masked" (authSuppressed || mask \`isSuffixOf\` auth)
        custom <- headerOf nfHeaders "x-custom-token"
        check c "clean.custom_header_masked" (custom == mask)
        explained <- maybe emptyMap pure (lookup "ok/explain" exps)
        exResult <- getp explained "result"
        check c "clean.explain_has_result" (ismap exResult)
        exHeaders <- case exResult of VMap _ -> getp exResult "headers"; _ -> pure VNoval
        session <- headerOf exHeaders "x-session-token"
        check c "clean.response_token_masked" (session == mask)

  runAction c "clean.sensitivity" $ do
    mtarget <- usableOp
    case mtarget of
      Nothing -> putStrLn skipLine
      Just target -> do
        sinks <- newIORef []
        sdk <- makeSdk (scenarios !! 1) sinks (Just [("active", VBool False)]) []
        ctrl <- emptyMap
        merr <- drive sdk target ctrl sinks

        -- Explaining a failure must not cost it its error.
        quiet <- newIORef []
        esdk <- makeSdk (scenarios !! 1) quiet (Just [("active", VBool False)]) []
        ectrl <- do ex <- emptyMap; jo [("explain", ex)]
        explained <- drive esdk target ectrl quiet
        let message = maybe (pure "") (\\e -> getStrD e "message" "")
        plainMsg <- message merr
        explainedMsg <- message explained
        check c "clean.off_explain_keeps_the_error" (not (null plainMsg) && explainedMsg == plainMsg)

        fs <- forms
        swept <- readIORef sinks
        let leaked = [n | (n, t) <- swept, not (null (leaksIn fs t))]
        check c "clean.off_shows_canary" (not (null leaked))
        case merr of
          Nothing -> check c "clean.off_404_throws" False
          Just e -> do
            sp <- getp e "spec"
            text <- jsonifyCompact sp
            check c "clean.off_raw_spec_carries_credential"
              (authSuppressed || canaryApikey \`isInfixOf\` text)
`
}


export {
  TestClean
}
