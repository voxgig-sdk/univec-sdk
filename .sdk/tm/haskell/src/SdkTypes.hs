-- Univec SDK core types.
--
-- The SDK data model is the vendored voxgig struct `Value` type
-- (VoxgigStruct.hs): a JSON-shaped, reference-stable (IORef-backed) node used
-- for ctx data, specs, options, transport payloads and results — exactly as
-- the Python/Go SDKs pass map[string]any around.
--
-- Haskell is purely functional, but the operation pipeline is inherently a
-- shared-mutable state machine (feature hooks observe and mutate the context
-- across stages, transport wrappers re-bind the fetcher). So the pipeline
-- objects — context, control (as Value maps), the utility bundle, features and
-- entities — carry `IORef` cells and the whole pipeline runs in `IO`. The
-- feature/utility indirection the dynamic donors get from late binding is
-- reproduced with function-valued record fields (the utility "registrar"
-- pattern). spec/response/result/operation/point/control are struct `Value`
-- maps (already IORef-backed, reference-stable), so no separate record types.
--
-- An SDK error is a struct Value map tagged `__sdkerr__` (see SdkHelpers.mkErr)
-- so it can travel on `ctx.out` alongside pipeline products; the throwing path
-- raises it as `SdkException`.

module SdkTypes where

import Control.Exception (Exception)
import Data.IORef (IORef)
import qualified Data.Map.Strict as Map

import VoxgigStruct (Value (..))

-- | Transport: (ctx, url, fetchdef) -> (response-map, Maybe error-map).
type Fetcher = Context -> String -> Value -> IO (Value, Maybe Value)

-- | param(ctx, paramdef) -> value.
type ParamFn = Context -> Value -> IO Value

-- | (product, Maybe error-map) — the pipeline utility return shape.
type UResult = IO (Value, Maybe Value)

-- | A lean view of the vendored struct exposed on utility.struct.
data StructApi = StructApi
  { sGetprop   :: Value -> Value -> IO Value
  , sSetprop   :: Value -> Value -> Value -> IO Value
  , sGetpath   :: Value -> Value -> IO Value
  , sGetelem   :: Value -> Value -> IO Value
  , sClone     :: Value -> IO Value
  , sMerge     :: [Value] -> IO Value
  , sItems     :: Value -> IO Value
  , sKeysof    :: Value -> IO [String]
  , sSize      :: Value -> IO Int
  , sIsempty   :: Value -> IO Bool
  , sStringify :: Value -> IO String
  , sJsonify   :: Value -> IO String
  , sEscurl    :: Value -> IO String
  , sEscre     :: Value -> IO String
  , sTransform :: Value -> Value -> IO Value
  , sValidate  :: Value -> Value -> IO Value
  , sSelect    :: Value -> Value -> IO Value
  , sWalk      :: (Value -> Value -> Value -> Value -> IO Value) -> Value -> IO Value
  }

-- | The utility bundle. `fetcher` (transport, wrapped by features) and `param`
-- vary per client/test; `custom` holds caller-supplied callables; the fixed
-- pipeline utilities are top-level functions in SdkRuntime.
data Utility = Utility
  { uCustom  :: IORef Value
  , uStruct  :: StructApi
  , uFetcher :: IORef Fetcher
  , uParam   :: IORef ParamFn
  }

-- | A pipeline feature: name/version/active bookkeeping, the `fOptions`
-- ordering carrier consulted by feature_add (__before__/__after__/__replace__),
-- an `init` and a name-keyed hook dispatch.
data Feature = Feature
  { fName    :: String
  , fVersion :: String
  , fActive  :: IORef Bool
  , fOptions :: IORef Value
  , fInit    :: Context -> Value -> IO ()
  , fHook    :: String -> Context -> IO ()
  }

-- | Operation description. entity/name/input are strings; points/alias Values.
data Operation = Operation
  { opEntity :: String
  , opName   :: String
  , opInput  :: String
  , opPoints :: Value
  , opAlias  :: Value
  }

data Client = Client
  { clMode        :: IORef String
  , clFeatures    :: IORef [Feature]
  , clOptions     :: IORef Value
  , clUtility     :: Utility
  , clRootctx     :: IORef (Maybe Context)
  , clTrack       :: IORef Value
  , clConfig      :: Value
  , clMakeFeature :: String -> IO Feature
  }

data Entity = Entity
  { eName    :: String
  , eClient  :: Client
  , eUtility :: Utility
  , eEntopts :: Value
  , eData    :: IORef Value
  , eMatch   :: IORef Value
  , eEntctx  :: IORef (Maybe Context)
  , eMake    :: IO Entity
  , eDataSet :: Value -> IO ()
  , eDataGet :: IO Value
  -- | Every operation resolves to the ENTITY, not the raw data — 'eList' to
  -- one per record. The record is reached through 'eDataGet'. 'Value' cannot
  -- carry an entity (it is a closed data union), so the CONTRACT lives in
  -- these signatures. See AGENTS.md "Entity operations return ENTITIES".
  , eLoad    :: Value -> Value -> IO Entity
  , eList    :: Value -> Value -> IO [Entity]
  , eCreate  :: Value -> Value -> IO Entity
  , eUpdate  :: Value -> Value -> IO Entity
  , eRemove  :: Value -> Value -> IO Entity
  -- | 'eRemove' resolves to the entity, marked. The instance KEEPS the data
  -- it held — a caller can still read what was deleted — but it is no longer
  -- a live record.
  , eDeleted     :: IORef Bool
  , eMarkDeleted :: IO ()
  -- | stream action args callopts -> a lazy list of result items.
  , eStream  :: String -> Value -> Value -> IO [Value]
  }

data Context = Context
  { cId       :: String
  , cOut      :: IORef Value
  , cCtrl     :: IORef Value
  , cMeta     :: IORef Value
  , cClient   :: IORef (Maybe Client)
  , cUtility  :: IORef (Maybe Utility)
  , cOp       :: IORef Operation
  , cPoint    :: IORef Value
  , cConfig   :: IORef Value
  , cEntopts  :: IORef Value
  , cOptions  :: IORef Value
  , cOpmap    :: IORef (Map.Map String Operation)
  , cResponse :: IORef Value
  , cResult   :: IORef Value
  , cSpec     :: IORef Value
  , cData     :: IORef Value
  , cReqdata  :: IORef Value
  , cMatch    :: IORef Value
  , cReqmatch :: IORef Value
  , cEntity   :: IORef (Maybe Entity)
  , cShared   :: IORef Value
  , cScratch  :: IORef Value
  }

-- | Construction spec for a context (the dynamic donors pass an untyped
-- ctxmap; here a typed optional-field builder, mirroring the rust CtxSpec).
data CtxSpec = CtxSpec
  { csOpname   :: Maybe String
  , csClient   :: Maybe Client
  , csUtility  :: Maybe Utility
  , csCtrl     :: Maybe Value
  , csMeta     :: Maybe Value
  , csConfig   :: Maybe Value
  , csEntopts  :: Maybe Value
  , csOptions  :: Maybe Value
  , csEntity   :: Maybe Entity
  , csShared   :: Maybe Value
  , csOpmap    :: Maybe (IORef (Map.Map String Operation))
  , csData     :: Maybe Value
  , csReqdata  :: Maybe Value
  , csMatch    :: Maybe Value
  , csReqmatch :: Maybe Value
  , csPoint    :: Maybe Value
  , csSpec     :: Maybe Value
  , csResult   :: Maybe Value
  , csResponse :: Maybe Value
  }

defaultCtxSpec :: CtxSpec
defaultCtxSpec = CtxSpec
  { csOpname = Nothing, csClient = Nothing, csUtility = Nothing, csCtrl = Nothing
  , csMeta = Nothing, csConfig = Nothing, csEntopts = Nothing, csOptions = Nothing
  , csEntity = Nothing, csShared = Nothing, csOpmap = Nothing, csData = Nothing
  , csReqdata = Nothing, csMatch = Nothing, csReqmatch = Nothing, csPoint = Nothing
  , csSpec = Nothing, csResult = Nothing, csResponse = Nothing }

-- | The exception raised on the throwing pipeline path; carries the error-map.
newtype SdkException = SdkException Value

instance Show SdkException where
  show (SdkException _) = "UnivecSDK error"

instance Exception SdkException
