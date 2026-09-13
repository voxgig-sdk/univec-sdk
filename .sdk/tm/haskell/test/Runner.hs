-- Univec SDK test runner. Drives the SDK template test suites (pipeline,
-- feature, netsim, custom-utility, primary-utility), the generated per-entity
-- tests, and the vendored struct corpus (the `struct` subtree of the shared
-- ../.sdk/test/test.json). Exits non-zero on any failure.

module Main where

import Control.Monad (forM_)
import Data.IORef
import System.Exit (exitFailure)

import Testutil
import SdkJson (jsonRead)
import StructCorpus (runStructCorpus)
import qualified TPipeline
import qualified TFeature
import qualified TNetsim
import qualified TCustomUtility
import qualified TPrimaryUtility
import qualified TPrimaryCorpus
import qualified SdkGenTests

main :: IO ()
main = do
  c <- newCounters

  raw <- readFile "../.sdk/test/test.json"
  alltests <- jsonRead raw

  TPipeline.tests c
  TFeature.tests c
  TNetsim.tests c
  TCustomUtility.tests c
  TPrimaryUtility.tests c alltests
  TPrimaryCorpus.tests c alltests
  SdkGenTests.genTests c

  fs <- readIORef (failures c)
  forM_ fs putStrLn
  p <- readIORef (npass c)
  f <- readIORef (nfail c)

  (sp, sf) <- runStructCorpus alltests

  putStrLn ("\nSDK    PASS " ++ show p ++ "  FAIL " ++ show f)
  putStrLn ("STRUCT PASS " ++ show sp ++ "  FAIL " ++ show sf)
  putStrLn ("TOTAL  PASS " ++ show (p + sp) ++ "  FAIL " ++ show (f + sf))

  if f + sf > 0 then exitFailure else pure ()
