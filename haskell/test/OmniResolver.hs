-- The corpus test runner: vendored @voxgig/omni driven through its NATIVE
-- API (`makeRunnerSpec` / `runsetFlagsArgs`), presented to the corpus suites
-- in the shape they use (`spec`, `getset`, `runsetArgs`, `report`). No compat
-- shim is vendored: the adapter below IS the whole bridge, per language, per
-- the vendor-tag rollout. It is the Haskell peer of
-- tm/ocaml/test/omni_resolver.ml, tm/rust/tests/omni_resolver/mod.rs and
-- tm/java/test/OmniResolver.java: the portable answer for a statically typed
-- port with no reflection — omni's `Provider` is closure-based, so nothing in
-- omni ever has to name this SDK's types.
--
-- Haskell-specific decisions, each load-bearing:
--
-- 1. TWO VALUE MODELS, ONE CONVERSION PAIR. `Omni.Json` is an immutable
--    variant; the SDK's `VoxgigStruct.Value` carries its maps and lists in
--    IORefs. Every crossing is an explicit `tostruct` / `toomni`.
--    `Omni.Absent` <-> `VNoval` and `Omni.Null` <-> `VNull` keep the two
--    no-value states the corpus distinguishes apart — which is why this port
--    needs neither go's `novalargs` spec rewrite nor lua/php's compat shim
--    for the corpus's ZERO-ARGUMENT entries. An entry with no `in`/`args`/
--    `ctx` reaches the subject as one `Absent`, which becomes this port's own
--    `VNoval`, so the arity correction is structural rather than a special
--    case.
--
-- 2. ARGUMENTS ARE WRITTEN BACK. `Omni.SubjectArgs`
--    (`[Json] -> IO ([Json], Json)`) is the channel omni provides for a
--    subject that MUTATES its arguments, which `match: {args: ...}` then
--    asserts on. Decision 1 hands the subject a CONVERTED COPY — a fresh
--    IORef tree, not omni's value — so every subject here runs through
--    `runsetFlagsArgs` and the wrapper converts the (mutated) Values back
--    into omni's array after the call.
--
--    THE IOREFS DO NOT MAKE THIS FREE. A dynamic port gets the write-back
--    from shared object identity: omni's stored argument and the subject's
--    argument are one object. Here the mutation is visible in the `Value`
--    the wrapper built and nowhere else, because omni holds `Json`. The
--    mutability buys the SDK utilities their in-place writes; it does not
--    bridge the models.
--
-- 3. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
--    A value-semantics consequence, not a choice, and the same one rust,
--    swift and ocaml hit. omni's `drive` stores the contextified first
--    argument as `entry.ctx` AND as `args[0]` — two copies of an immutable
--    value — and reads `entry.ctx` for the ctx base when checking. A
--    subject's post-call writes (decision 2) can never reach that copy, and
--    the `primary` entries that assert POST-call state would all read stale.
--    `args[0]` IS the ctx of a ctx entry (omni itself sets
--    `args = [entry.ctx]`), and the runner reads that array back after an
--    args-subject call — so moving the assertion from `ctx` to `args.0`
--    reads the SAME map, post-call, and preserves every leaf: nothing is
--    dropped, weakened or skipped. `retargetctx` does that rewrite on the
--    spec handed to the engine.
--
-- 4. KEY ORDER AND NUMBERS NEED NOTHING. omni's Haskell port models a map as
--    an ordered assoc list in document order and compares maps
--    order-independently (`deepequal`); this SDK's map is also
--    insertion-ordered. Both read every JSON number as `Double`. The round
--    trip is lossless in both directions — unlike rust (BTreeMap) or
--    go/csharp/java (integral doubles).
--
-- 5. SUBJECT FAILURES ARRIVE AS `ErrorCall`. omni's `errmessage` renders an
--    unknown exception through `displayException`, which would turn this
--    SDK's branded error into its `Show` form and break every entry that
--    matches on the message. So the wrapper translates a caught exception to
--    `ErrorCall` carrying just the message. `OmniError` is deliberately NOT
--    used: omni re-raises that as a runner error rather than treating it as
--    a candidate for an `err` expectation.
--
-- 6. FAILURES ARE ACCUMULATED, NOT RAISED. omni stops a group at its first
--    bad entry and raises; the corpus suites report the whole corpus in one
--    run. `runsetArgs` records the message and carries on, so one run still
--    names every section that regressed rather than only the first.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module OmniResolver
  ( Runner
  , newRunner
  , getset
  , runnerSpec
  , runsetArgs
  , tostruct
  , toomni
  , runnerPass
  , runnerFail
  , runnerFailures
  ) where

import Control.Exception (SomeException, ErrorCall (..), displayException, throwIO, try)
import Control.Monad (foldM, forM, forM_)
import Data.IORef

import qualified Omni as O
import VoxgigStruct
  ( Value (..)
  , emptyList
  , emptyMap
  , keysof
  , getprop
  , mkList
  , setprop
  )


-- The corpus runner: omni's pack plus this run's accumulated outcome.
data Runner = Runner
  { rnPack :: O.RunPack
  , rnPass :: IORef Int
  , rnFail :: IORef Int
  , rnMsgs :: IORef [String]
  }


runnerPass :: Runner -> IO Int
runnerPass = readIORef . rnPass

runnerFail :: Runner -> IO Int
runnerFail = readIORef . rnFail

runnerFailures :: Runner -> IO [String]
runnerFailures = readIORef . rnMsgs


-- ---- the conversion pair (decision 1) --------------------------------

-- omni's immutable Json -> this SDK's mutable Value.
tostruct :: O.Json -> IO Value
tostruct = \case
  O.Absent -> pure VNoval
  O.Null -> pure VNull
  O.Bool b -> pure (VBool b)
  O.Num n -> pure (VNum n)
  O.Str s -> pure (VStr s)
  O.JList xs -> mapM tostruct xs >>= mkList
  O.JMap es -> do
    m <- emptyMap
    forM_ es $ \(k, v) -> do
      sv <- tostruct v
      _ <- setprop m (VStr k) sv
      pure ()
    pure m


-- This SDK's Value -> omni's Json. A VFunc has no corpus representation and
-- becomes Absent: the corpus never asserts on one, and rendering it as a
-- string would make a match read a function where it expects no value.
toomni :: Value -> IO O.Json
toomni = \case
  VNoval -> pure O.Absent
  VNull -> pure O.Null
  VBool b -> pure (O.Bool b)
  VNum n -> pure (O.Num n)
  VStr s -> pure (O.Str s)
  VSentinel t -> pure (O.Str t)
  VFunc _ -> pure O.Absent
  VList r -> do
    xs <- readIORef r
    O.JList <$> mapM toomni xs
  VMap r -> do
    es <- readIORef r
    O.JMap <$> forM es (\(k, v) -> (,) k <$> toomni v)


-- ---- the spec rewrite (decision 3) -----------------------------------

-- Move every entry's `match.ctx` to `match.args.0`, everywhere in the spec.
-- Applied once, to the whole spec, before the engine sees it: an entry is
-- reached by walking maps and lists rather than by knowing the corpus's
-- shape, so a section that nests its entries differently is still covered.
retargetctx :: O.Json -> O.Json
retargetctx node = case node of
  O.JMap es -> O.JMap (map (\(k, v) -> (k, retargetctx v)) (rewrite es))
  O.JList xs -> O.JList (map retargetctx xs)
  _ -> node
  where
    rewrite es = case lookup "match" es of
      Just m@(O.JMap mes) | not (O.isabsent (O.jget m "ctx")) ->
        let rest = filter ((/= "ctx") . fst) mes
            args = O.JMap [("0", O.jget m "ctx")]
            merged = case lookup "args" mes of
              Just (O.JMap ames) ->
                O.JMap (("0", O.jget m "ctx") : filter ((/= "0") . fst) ames)
              _ -> args
         in map (\(k, v) -> if k == "match"
                            then (k, O.JMap (("args", merged) : filter ((/= "args") . fst) rest))
                            else (k, v)) es
      _ -> es


-- ---- construction ----------------------------------------------------

-- A runner over the whole corpus, rooted at `name` (the corpus subtree the
-- suite drives, e.g. "primary").
newRunner :: O.Json -> String -> IO Runner
newRunner alltests name = do
  pack <- O.makeRunnerSpec (retargetctx alltests) O.emptyProvider name
  Runner pack <$> newIORef 0 <*> newIORef 0 <*> newIORef []


-- The set for a section, by name. The corpus nests a section's entries one
-- level down (`<section>.basic.set`), and omni's `packSet` is a single-level
-- lookup on the spec it was rooted at — so the path is walked here, as the
-- ocaml peer's `getset r [name; "basic"]` does.
getset :: Runner -> String -> O.Json
getset r name = O.getpath (O.packSpec (rnPack r)) [name, "basic"]


-- The spec the engine holds, for a section that reads its own DEF block.
runnerSpec :: Runner -> O.Json
runnerSpec = O.packSpec . rnPack


-- ---- driving (decisions 2, 5, 6) -------------------------------------

-- Run one section through a subject that takes the corpus's arguments as
-- Values and may mutate them in place.
--
-- The subject's own failure is a candidate for an `err` expectation, so it is
-- translated to `ErrorCall` (decision 5) and left to omni. A failure of the
-- SET is this run's to record (decision 6), never to raise.
runsetArgs :: Runner -> String -> ([Value] -> IO Value) -> IO ()
runsetArgs r name subject = do
  let pack = rnPack r
  outcome <- try (O.runsetFlagsArgs pack (getset r name) O.defaultFlags wrapped)
  case outcome of
    Right () -> modifyIORef' (rnPass r) (+ 1)
    Left (e :: SomeException) -> do
      modifyIORef' (rnFail r) (+ 1)
      modifyIORef' (rnMsgs r) (++ ["primary." ++ name ++ ": " ++ O.errmessage e])
  where
    wrapped :: O.SubjectArgs
    wrapped jargs = do
      vargs <- mapM tostruct jargs
      res <- try (subject vargs)
      -- The arguments are converted back WHETHER OR NOT the subject failed:
      -- an `err` entry can still assert on the state the call left behind,
      -- and omni reads the array either way.
      jargs' <- mapM toomni vargs
      case res of
        Right v -> do
          jv <- toomni v
          pure (jargs', jv)
        Left (e :: SomeException) -> throwIO (ErrorCall (plainmessage e))


-- The message a corpus `err` entry matches on, stripped of the exception's
-- own rendering. `displayException` on this SDK's branded error yields its
-- Show form; the first line of it is the message the corpus wrote.
plainmessage :: SomeException -> String
plainmessage e = case lines (displayException e) of
  (l : _) -> l
  [] -> displayException e
