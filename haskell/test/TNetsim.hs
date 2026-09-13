-- Network-behaviour simulation over the offline mock transport. The `test`
-- feature accepts an optional `net` config so unit tests can exercise slow,
-- failing and offline conditions without a live server. These drive the
-- transport through direct(), which needs no entity.

module TNetsim (tests) where

import Data.IORef (readIORef)

import VoxgigStruct (Value (..))
import SdkTypes
import SdkHelpers
import qualified SdkFeatures as F
import qualified SdkClient as C
import Testutil

tests :: Counters -> IO ()
tests c = do
  runTest c "netsim.offline_fails" $ do
    net <- jo [("offline", VBool True)]
    opt <- jo [("net", net)]
    sdk <- C.testSdk opt VNoval
    args <- jo [("path", VStr "/ping")]
    res <- F.direct sdk args
    ok <- getp res "ok"
    pure (not (isTrueV ok))

  runTest c "netsim.failstatus_surfaces_status" $ do
    net <- jo [("failTimes", VNum 1), ("failStatus", VNum 503)]
    opt <- jo [("net", net)]
    sdk <- C.testSdk opt VNoval
    args <- jo [("path", VStr "/ping")]
    res <- F.direct sdk args
    ok <- getp res "ok"
    st <- getp res "status"
    pure (not (isTrueV ok) && toInt st == 503)

  runTest c "netsim.errortimes_conn_error" $ do
    net <- jo [("errorTimes", VNum 1)]
    opt <- jo [("net", net)]
    sdk <- C.testSdk opt VNoval
    args <- jo [("path", VStr "/ping")]
    res <- F.direct sdk args
    ok <- getp res "ok"
    pure (not (isTrueV ok))

  runTest c "netsim.plain_test_mode" $ do
    sdk <- C.testSdk0
    m <- readIORef (clMode sdk)
    pure (m == "test")
