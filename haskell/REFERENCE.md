# Univec Haskell SDK Reference

Complete API reference for the Univec Haskell SDK.


## Client

### Constructors

```haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

makeClient :: IO Sdk.Client
makeClient = do
  opts <- jo [("base", VStr "https://api.example.com")]
  Sdk.newSdk opts
```

Construct a live SDK client.

**Functions:**

| Function | Signature | Description |
| --- | --- | --- |
| `newSdk` | `Value -> IO Client` | Construct a client from an options map. |
| `newSdk0` | `IO Client` | Construct a client with defaults. |

**Options (map keys):**

| Key | Type | Description |
| --- | --- | --- |
| `apikey` | `String` | API key for authentication. |
| `base` | `String` | Base URL for API requests. |
| `prefix` | `String` | URL prefix appended after base. |
| `suffix` | `String` | URL suffix appended after path. |
| `headers` | `Value` | Custom headers for all requests. |
| `feature` | `Value` | Feature configuration. |
| `system` | `Value` | System overrides (e.g. custom fetch). |


### Test constructors

```haskell
client <- Sdk.testSdk0
```

`testSdk :: Value -> Value -> IO Client` constructs a test client with mock
features active (`testSdk0 :: IO Client` for the no-argument form). Pass
`VNoval` for defaults.


### Entity accessors

#### `convert :: Client -> Value -> IO Entity`

Construct a `Convert` entity bound to the client. Pass `VNoval` for no initial options.

#### `embed :: Client -> Value -> IO Entity`

Construct a `Embed` entity bound to the client. Pass `VNoval` for no initial options.

#### `ephemeral_key :: Client -> Value -> IO Entity`

Construct a `EphemeralKey` entity bound to the client. Pass `VNoval` for no initial options.

#### `model :: Client -> Value -> IO Entity`

Construct a `Model` entity bound to the client. Pass `VNoval` for no initial options.

### HTTP escape hatches

#### `direct :: Client -> Value -> IO Value` (module `SdkFeatures`)

Make a direct HTTP request to any API endpoint. Returns a result `Value` with
`ok`, `status`, `headers`, and `data` (or `err` on failure). This escape
hatch never raises — branch on `getp result "ok"`.

**Argument (map keys):**

| Key | Type | Description |
| --- | --- | --- |
| `path` | `String` | URL path with optional `{param}` placeholders. |
| `method` | `String` | HTTP method (default: `"GET"`). |
| `params` | `Value` | Path parameter values. |
| `query` | `Value` | Query string parameters. |
| `headers` | `Value` | Request headers (merged with defaults). |
| `body` | `Value` | Request body (maps are JSON-serialized). |

#### `prepare :: Client -> Value -> IO Value` (module `SdkFeatures`)

Prepare a fetch definition without sending. Returns the `fetchdef` and raises on error.


---

## Convert

```haskell
  ent <- Sdk.convert sdk VNoval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `[Value]` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Yes | Model space to translate into. |
| `texts` | `[Value]` | Yes | Texts to embed and translate. |

### Operations

#### `eCreate ent data ctrl :: IO Entity`

Create a new entity with the given data. Resolves to the ENTITY (read the record with `eDataGet`) and raises on error.

```haskell
  ent <- Sdk.convert sdk VNoval
  d <- jo
    [ ("bridge_model", VStr "example_bridge_model")   -- String
    , ("embeddings", VNoval)   -- [Value]
    , ("source_model", VStr "example_source_model")   -- String
    , ("target_model", VStr "example_target_model")   -- String
    , ("texts", VNoval)   -- [Value]
    ]
  ctrl <- emptyMap
  result <- Sdk.eCreate ent d ctrl   -- the ENTITY
  d2 <- Sdk.eDataGet result
```

### Common Fields

#### `eDataGet :: IO Value`

Get the entity data.

#### `eDataSet :: Value -> IO ()`

Set the entity data.

#### `eStream :: String -> Value -> Value -> IO [Value]`

Run an operation as a lazy stream of result items.

#### `eMake :: IO Entity`

Create a new `Convert` entity with the same options.

#### `eName :: String`

The entity name.


---

## Embed

```haskell
  ent <- Sdk.embed sdk VNoval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `[Value]` | Yes | One vector per input text, in input order. |
| `model` | `String` | Yes | Model that produced the vectors. |
| `texts` | `[Value]` | Yes | Texts to embed. |

### Operations

#### `eCreate ent data ctrl :: IO Entity`

Create a new entity with the given data. Resolves to the ENTITY (read the record with `eDataGet`) and raises on error.

```haskell
  ent <- Sdk.embed sdk VNoval
  d <- jo
    [ ("embeddings", VNoval)   -- [Value]
    , ("model", VStr "example_model")   -- String
    , ("texts", VNoval)   -- [Value]
    ]
  ctrl <- emptyMap
  result <- Sdk.eCreate ent d ctrl   -- the ENTITY
  d2 <- Sdk.eDataGet result
```

### Common Fields

#### `eDataGet :: IO Value`

Get the entity data.

#### `eDataSet :: Value -> IO ()`

Set the entity data.

#### `eStream :: String -> Value -> Value -> IO [Value]`

Run an operation as a lazy stream of result items.

#### `eMake :: IO Entity`

Create a new `Embed` entity with the same options.

#### `eName :: String`

The entity name.


---

## EphemeralKey

```haskell
  ent <- Sdk.ephemeral_key sdk VNoval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `Int` | Yes | Calls permitted per day. |
| `dailyUsed` | `Int` | Yes | Calls already used today. |
| `key` | `String` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | Yes | When the daily allowance resets. |

### Operations

#### `eCreate ent data ctrl :: IO Entity`

Create a new entity with the given data. Resolves to the ENTITY (read the record with `eDataGet`) and raises on error.

```haskell
  ent <- Sdk.ephemeral_key sdk VNoval
  d <- jo
    [ ("dailyLimit", VNum 1)   -- Int
    , ("dailyUsed", VNum 1)   -- Int
    , ("key", VStr "example_key")   -- String
    , ("resetsAt", VStr "example_resetsAt")   -- String
    ]
  ctrl <- emptyMap
  result <- Sdk.eCreate ent d ctrl   -- the ENTITY
  d2 <- Sdk.eDataGet result
```

### Common Fields

#### `eDataGet :: IO Value`

Get the entity data.

#### `eDataSet :: Value -> IO ()`

Set the entity data.

#### `eStream :: String -> Value -> Value -> IO [Value]`

Run an operation as a lazy stream of result items.

#### `eMake :: IO Entity`

Create a new `EphemeralKey` entity with the same options.

#### `eName :: String`

The entity name.


---

## Model

```haskell
  ent <- Sdk.model sdk VNoval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Value` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | No | Hardware backend, e.g. |
| `modelCard` | `Value` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Yes | Model identifier used in requests. |
| `sequenceLen` | `Int` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `Int` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String` | No | Convert models only: the source model space. |
| `targetDim` | `Int` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String` | Yes | The model space produced. |

### Operations

#### `eList ent match ctrl :: IO [Entity]`

List entities matching the given criteria. The match is optional — pass an empty map to list all records. Resolves to one ENTITY per record and raises on error.

```haskell
  ent <- Sdk.model sdk VNoval
  match <- emptyMap
  ctrl <- emptyMap
  results <- Sdk.eList ent match ctrl   -- one ENTITY per record
  datas <- mapM Sdk.eDataGet results
```

### Common Fields

#### `eDataGet :: IO Value`

Get the entity data.

#### `eDataSet :: Value -> IO ()`

Set the entity data.

#### `eStream :: String -> Value -> Value -> IO [Value]`

Run an operation as a lazy stream of result items.

#### `eMake :: IO Entity`

Create a new `Model` entity with the same options.

#### `eName :: String`

The entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `audit` | 0.0.1 | Structured audit trail of operations |
| `cache` | 0.0.1 | Response caching for safe read requests |
| `clienttrack` | 0.0.1 | Client identity and per-request correlation headers |
| `cost` | 0.0.1 | Cost tracking and spend budget for API calls |
| `debug` | 0.0.1 | Request/response capture ring buffer for debugging |
| `idempotency` | 0.0.1 | Idempotency keys for safe retries of mutating operations |
| `log` | 0.0.1 | Structured request and response logging |
| `metrics` | 0.0.1 | Statistics capture: per-operation counters and latency |
| `netsim` | 0.0.1 | Network behaviour simulation for offline testing (latency, failures, outages) |
| `paging` | 0.0.1 | Pagination signals for list operations |
| `proxy` | 0.0.1 | Outbound HTTP(S) proxy routing |
| `ratelimit` | 0.0.1 | Client-side rate limiting via a token bucket |
| `rbac` | 0.0.1 | Client-side role/permission enforcement |
| `retry` | 0.0.1 | Automatic retry of transient failures with exponential backoff |
| `streaming` | 0.0.1 | Incremental streaming of list results via async iteration |
| `telemetry` | 0.0.1 | Distributed tracing spans with W3C trace-context propagation |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |
| `timeout` | 0.0.1 | Per-request timeout with transport abort |


Features are activated via the `feature` option:

```haskell
  active <- jo [("active", VBool True)]
  featureCfg <- jo
    [ ("audit", active)
    , ("cache", active)
    , ("clienttrack", active)
    , ("cost", active)
    , ("debug", active)
    , ("idempotency", active)
    , ("log", active)
    , ("metrics", active)
    , ("netsim", active)
    , ("paging", active)
    , ("proxy", active)
    , ("ratelimit", active)
    , ("rbac", active)
    , ("retry", active)
    , ("streaming", active)
    , ("telemetry", active)
    , ("test", active)
    , ("timeout", active)
    ]
  opts <- jo [("feature", featureCfg)]
  client <- Sdk.newSdk opts
```

