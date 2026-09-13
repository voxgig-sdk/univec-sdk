-- Custom utility overrides: caller-supplied callables in options.utility land
-- on utility.custom during option resolution.

module TCustomUtility (tests) where

import Control.Monad (forM_, foldM)
import Data.IORef (readIORef)

import VoxgigStruct (Value (..), emptyMap, isfunc)
import SdkTypes
import SdkHelpers
import qualified SdkClient as C
import Testutil

utils :: [(String, String)]
utils =
  [ ("auth", "AUTH"), ("body", "BODY"), ("contextify", "CONTEXTIFY")
  , ("done", "DONE"), ("error", "ERROR"), ("findparam", "FINDPARAM")
  , ("fullurl", "FULLURL"), ("headers", "HEADERS"), ("method", "METHOD")
  , ("operator", "OPERATOR"), ("params", "PARAMS"), ("query", "QUERY")
  , ("reqform", "REQFORM"), ("request", "REQUEST"), ("resbasic", "RESBASIC")
  , ("resbody", "RESBODY"), ("resform", "RESFORM"), ("resheaders", "RESHEADERS")
  , ("response", "RESPONSE"), ("result", "RESULT"), ("spec", "SPEC") ]

tests :: Counters -> IO ()
tests c = do
  runTest c "customUtility.basic" $ do
    utilOpts <- emptyMap
    forM_ utils $ \(k, tag) ->
      setp utilOpts k (VFunc (\_ _ _ _ -> jo [("util", VStr tag)]))
    opts <- jo [("apikey", VStr "APIKEY01"), ("utility", utilOpts)]
    sdk <- C.testSdk VNoval opts
    let u = clUtility sdk
    custom <- readIORef (uCustom u)
    foldM (\ok (k, tag) -> do
      f <- getp custom k
      if not (isfunc f) then pure False
      else do out <- callVfn f VNoval; uv <- getp out "util"; pure (ok && vstring uv == tag)) True utils
