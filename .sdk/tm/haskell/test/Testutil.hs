-- Minimal SDK test harness: a shared Counters record accumulates pass/fail;
-- `runTest` executes an IO Bool assertion (exceptions count as failures);
-- `check` records a pure boolean. A final `summary` prints counts and exits
-- non-zero on any failure.

{-# LANGUAGE ScopedTypeVariables #-}

module Testutil where

import Control.Exception (SomeException, try)
import Data.IORef
import System.Exit (exitFailure)

data Counters = Counters
  { npass    :: IORef Int
  , nfail    :: IORef Int
  , failures :: IORef [String]
  }

newCounters :: IO Counters
newCounters = Counters <$> newIORef 0 <*> newIORef 0 <*> newIORef []

recordPass :: Counters -> IO ()
recordPass c = modifyIORef' (npass c) (+ 1)

recordFail :: Counters -> String -> IO ()
recordFail c msg = do modifyIORef' (nfail c) (+ 1); modifyIORef' (failures c) (++ ["FAIL " ++ msg])

-- Record a pure boolean assertion.
check :: Counters -> String -> Bool -> IO ()
check c name ok = if ok then recordPass c else recordFail c name

-- Run an IO Bool assertion; an exception (or False) is a failure.
runTest :: Counters -> String -> IO Bool -> IO ()
runTest c name act = do
  r <- try act :: IO (Either SomeException Bool)
  case r of
    Right True -> recordPass c
    Right False -> recordFail c (name ++ " (assertion false)")
    Left e -> recordFail c (name ++ " (exception: " ++ firstLine (show e) ++ ")")
  where firstLine s = case lines s of (l : _) -> l; [] -> s

-- Run an IO action that raises on failure (used for imperative-style checks).
runAction :: Counters -> String -> IO () -> IO ()
runAction c name act = do
  r <- try act :: IO (Either SomeException ())
  case r of
    Right () -> recordPass c
    Left e -> recordFail c (name ++ " (exception: " ++ firstLine (show e) ++ ")")
  where firstLine s = case lines s of (l : _) -> l; [] -> s

summary :: Counters -> IO ()
summary c = do
  fs <- readIORef (failures c)
  mapM_ putStrLn fs
  p <- readIORef (npass c)
  f <- readIORef (nfail c)
  putStrLn ("\nSDK PASS " ++ show p ++ "  FAIL " ++ show f)
  if f > 0 then exitFailure else pure ()
