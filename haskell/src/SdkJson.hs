-- Self-contained JSON reader building struct `Value` nodes directly (no
-- third-party dependency beyond the `array` boot library). Uses O(1) array
-- indexing so large corpora parse in linear time.
--
-- Lives in src/ rather than test/ because SdkConfig needs it: above a size
-- threshold the API model is embedded as a JSON string constant and parsed
-- once at load (sdkgen rung L1) instead of being built as a CV literal. It is
-- still what the struct corpus runner and the entity-fixture tests use.

{-# LANGUAGE LambdaCase #-}

module SdkJson (jsonRead) where

import Data.Array (Array, listArray, (!))
import Data.Char (chr)
import Data.IORef
import Numeric (readHex)

import VoxgigStruct

jsonRead :: String -> IO Value
jsonRead s0 = do
  posRef <- newIORef 0
  let n = length s0
      a = listArray (0, max 0 (n - 1)) s0 :: Array Int Char
      at i = a ! i
      peek = do p <- readIORef posRef; return (if p < n then Just (at p) else Nothing)
      adv = modifyIORef' posRef (+ 1)
      skipWs = do
        p <- readIORef posRef
        if p < n && (at p `elem` " \t\n\r") then adv >> skipWs else return ()
      pval = do
        skipWs
        mc <- peek
        case mc of
          Just '{' -> pobj
          Just '[' -> parr
          Just '"' -> VStr <$> pstr
          Just 't' -> modifyIORef' posRef (+ 4) >> return (VBool True)
          Just 'f' -> modifyIORef' posRef (+ 5) >> return (VBool False)
          Just 'n' -> modifyIORef' posRef (+ 4) >> return VNull
          _ -> pnum
      pobj = do
        adv; skipWs
        mc <- peek
        if mc == Just '}' then adv >> emptyMap
        else do
          m <- emptyMap
          let loop = do
                skipWs
                k <- pstr
                skipWs; adv  -- ':'
                v <- pval
                _ <- setprop m (VStr k) v
                skipWs
                c <- peek >>= \case Just ch -> adv >> return ch; Nothing -> return '}'
                if c == ',' then loop else return m
          loop
      parr = do
        adv; skipWs
        mc <- peek
        if mc == Just ']' then adv >> emptyList
        else do
          accRef <- newIORef []
          let loop = do
                v <- pval
                modifyIORef' accRef (v :)
                skipWs
                c <- peek >>= \case Just ch -> adv >> return ch; Nothing -> return ']'
                if c == ',' then loop else do acc <- readIORef accRef; mkList (reverse acc)
          loop
      pstr = do
        adv  -- opening quote
        bRef <- newIORef []
        let loop = do
              p <- readIORef posRef
              let c = at p
              adv
              if c == '"' then do b <- readIORef bRef; return (reverse b)
              else if c == '\\' then do
                p2 <- readIORef posRef
                let e = at p2
                adv
                case e of
                  '"' -> push '"' >> loop
                  '\\' -> push '\\' >> loop
                  '/' -> push '/' >> loop
                  'n' -> push '\n' >> loop
                  't' -> push '\t' >> loop
                  'r' -> push '\r' >> loop
                  'b' -> push '\b' >> loop
                  'f' -> push '\f' >> loop
                  'u' -> do
                    pp <- readIORef posRef
                    let hex = [at (pp + k) | k <- [0 .. 3], pp + k < n]
                    modifyIORef' posRef (+ 4)
                    case readHex hex of { [(code, _)] -> push (chr code) >> loop; _ -> loop }
                  _ -> push e >> loop
              else push c >> loop
            push c = modifyIORef' bRef (c :)
        loop
      pnum = do
        start <- readIORef posRef
        let go = do
              p <- readIORef posRef
              if p < n && (at p `elem` "0123456789-+.eE") then adv >> go else return ()
        go
        end <- readIORef posRef
        let tok = [at j | j <- [start .. end - 1]]
        return (VNum (read tok))
  pval
