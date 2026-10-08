-- Minimal SDK test harness: a shared Counters record accumulates pass/fail;
-- `runTest` executes an IO Bool assertion (exceptions count as failures);
-- `check` records a pure boolean. A final `summary` prints counts and exits
-- non-zero on any failure.

{-# LANGUAGE ScopedTypeVariables #-}

module Testutil where

import Control.Exception (SomeException, evaluate, fromException, try)
import Data.IORef
import System.Exit (exitFailure)
import System.IO (IOMode (ReadMode), hGetContents, hSetEncoding, utf8, withFile)

import SdkHelpers (errCode, errMsg)
import SdkTypes (SdkException (..))

data Counters = Counters
  { npass    :: IORef Int
  , nfail    :: IORef Int
  , failures :: IORef [String]
  }

-- A file's text decoded as UTF-8: readFile decodes with the locale's
-- encoding, which cannot read the generated docs under a C or POSIX locale.
readUtf8 :: FilePath -> IO String
readUtf8 path = withFile path ReadMode $ \h -> do
  hSetEncoding h utf8
  s <- hGetContents h
  _ <- evaluate (length s)
  pure s

newCounters :: IO Counters
newCounters = Counters <$> newIORef 0 <*> newIORef 0 <*> newIORef []

recordPass :: Counters -> IO ()
recordPass c = modifyIORef' (npass c) (+ 1)

recordFail :: Counters -> String -> IO ()
recordFail c msg = do modifyIORef' (nfail c) (+ 1); modifyIORef' (failures c) (++ ["FAIL " ++ msg])

-- Record a pure boolean assertion.
check :: Counters -> String -> Bool -> IO ()
check c name ok = if ok then recordPass c else recordFail c name

-- The first line of what an exception says. An SdkException's Show cannot read
-- the error it carries, so its code and message stand in.
failureText :: SomeException -> IO String
failureText e = firstLine <$> case fromException e of
  Just (SdkException v) -> do code <- errCode v; msg <- errMsg v; pure (code ++ ": " ++ msg)
  Nothing -> pure (show e)
  where firstLine s = case lines s of (l : _) -> l; [] -> s

-- Run an IO Bool assertion; an exception (or False) is a failure.
runTest :: Counters -> String -> IO Bool -> IO ()
runTest c name act = do
  r <- try act :: IO (Either SomeException Bool)
  case r of
    Right True -> recordPass c
    Right False -> recordFail c (name ++ " (assertion false)")
    Left e -> do t <- failureText e; recordFail c (name ++ " (exception: " ++ t ++ ")")

-- Run an IO action that raises on failure (used for imperative-style checks).
runAction :: Counters -> String -> IO () -> IO ()
runAction c name act = do
  r <- try act :: IO (Either SomeException ())
  case r of
    Right () -> recordPass c
    Left e -> do t <- failureText e; recordFail c (name ++ " (exception: " ++ t ++ ")")

summary :: Counters -> IO ()
summary c = do
  fs <- readIORef (failures c)
  mapM_ putStrLn fs
  p <- readIORef (npass c)
  f <- readIORef (nfail c)
  putStrLn ("\nSDK PASS " ++ show p ++ "  FAIL " ++ show f)
  if f > 0 then exitFailure else pure ()
