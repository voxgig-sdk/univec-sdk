# Univec Haskell SDK



The Haskell SDK for the Univec API — an entity-oriented client following idiomatic Haskell conventions (pure functions, explicit `IO`, and the dependency-free vendored `Value` struct model).

The SDK exposes the API as capitalised, semantic **Entities** — for example `convert sdk VNoval` — each
carrying a small, uniform set of operations (`eList`, `eCreate`) instead of raw URL
paths and query strings. You work with named resources and verbs, which
keeps the cognitive load low.

> Other languages, the CLI, and MCP server live alongside this one — see
> the [top-level README](../README.md).


## Install
This package is not yet published to Hackage. Install it from the GitHub
release tag (`haskell/vX.Y.Z`, see [Releases](https://github.com/voxgig-sdk/univec-sdk/releases)) or
from a source checkout. The runtime has no third-party dependencies (only the
GHC boot libraries: `base`, `containers`, `array`, `time`), so the
bundled Makefile drives stock GHC with no cabal solve:

```bash
cd haskell && make test
```

A `.cabal` file is also generated for use with `cabal`/`stack`:

```bash
cd haskell && cabal build
```


## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.

### 1. Create a client

```haskell
import System.Environment (lookupEnv)
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..), emptyMap)
import SdkHelpers (jo)

main :: IO ()
main = do
  mkey <- lookupEnv "UNIVEC_APIKEY"
  opts <- jo [("apikey", maybe VNoval VStr mkey)]
  sdk <- Sdk.newSdk opts
```

Entity operations raise on error (via `Control.Exception.throwIO`) and
return the bare result `Value`. Wrap a call in `Control.Exception.try`
to recover from failures.

### 4. Create, update, and remove

```haskell
  createEnt <- Sdk.convert sdk VNoval
  d <- jo [("bridge_model", VStr "example_bridge_model"), ("embeddings", VNoval), ("source_model", VStr "example_source_model"), ("target_model", VStr "example_target_model"), ("texts", VNoval)]
  cctrl <- emptyMap
  created <- Sdk.eCreate createEnt d cctrl
  print =<< Sdk.eDataGet created
```


## Error handling

Entity operations reject on failure, so wrap them in `try` / `catch`:

```ts
try {
  const models = await client.Model().list()
  console.log(models)
} catch (err) {
  console.error('list failed:', err)
}
```

The low-level `direct()` method does **not** throw — it returns the
value or an `Error`, so check the result before using it:

```ts
const result = await client.direct({
  path: '/api/resource/{id}',
  method: 'GET',
  params: { id: 'example_id' },
})

if (result instanceof Error) {
  throw result
}
```


## How-to guides

### Make a direct HTTP request

For endpoints not covered by entity accessors, use `direct` — it never
raises and returns a result `Value` you branch on via its `ok` field:

```haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..))
import SdkHelpers (jo, getp)

main :: IO ()
main = do
  sdk <- Sdk.newSdk0
  params <- jo [("id", VStr "example")]
  args <- jo [("path", VStr "/api/resource/{id}"), ("method", VStr "GET"), ("params", params)]
  result <- F.direct sdk args
  ok <- getp result "ok"
  case ok of
    VBool True -> do
      status <- getp result "status"   -- e.g. VNum 200
      body <- getp result "data"       -- the response body
      print (status, body)
    _ -> do
      -- A non-2xx response carries status + data (the error body); a
      -- transport-level failure carries err instead.
      status <- getp result "status"
      err <- getp result "err"
      print (status, err)
```

### Prepare a request without sending it

```haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..))
import SdkHelpers (jo, getp)

main :: IO ()
main = do
  sdk <- Sdk.newSdk0
  params <- jo [("id", VStr "example")]
  args <- jo [("path", VStr "/api/resource/{id}"), ("method", VStr "DELETE"), ("params", params)]
  -- prepare returns the fetch definition and raises on error.
  fetchdef <- F.prepare sdk args
  url <- getp fetchdef "url"
  method <- getp fetchdef "method"
  print (url, method)
```

### Use test mode

Create a mock client for unit testing — no server required:

```haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..), emptyMap)
import SdkHelpers (jo)

main :: IO ()
main = do
  sdk <- Sdk.testSdk0
  ent <- Sdk.model sdk VNoval
  arg <- emptyMap
  ctrl <- emptyMap
  -- Entity ops return the bare record and raise on error.
  model <- Sdk.eList ent arg ctrl
  print model
```

### Use a custom fetch function

Replace the HTTP transport with your own `VFunc` under `system.fetch`:

```haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo, jsonThunk)

customClient :: IO Sdk.Client
customClient = do
  let mockFetch = VFunc (\_ _ _ _ -> do
        body <- jo [("id", VStr "mock01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk body)])
  sys <- jo [("fetch", mockFetch)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  Sdk.newSdk opts
```

### Run live tests

Create a `.env.local` file at the project root:

```
UNIVEC_TEST_LIVE=TRUE
UNIVEC_APIKEY=<your-key>
```

Then run the suite (stock GHC, no third-party dependencies):

```bash
cd haskell && make test
```


## Reference

### Client constructors

```haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

makeClient :: IO Sdk.Client
makeClient = do
  opts <- jo [("base", VStr "https://api.example.com")]
  Sdk.newSdk opts
```

`newSdk :: Value -> IO Client` constructs a client from an options map;
`newSdk0 :: IO Client` is the no-argument convenience form.

| Option (map key) | Type | Description |
| --- | --- | --- |
| `apikey` | `String` | API key for authentication. |
| `base` | `String` | Base URL of the API server. |
| `prefix` | `String` | URL path prefix prepended to all requests. |
| `suffix` | `String` | URL path suffix appended to all requests. |
| `headers` | `Value` | Custom headers for all requests. |
| `feature` | `Value` | Feature activation flags. |
| `system` | `Value` | System overrides (e.g. custom `fetch` function). |

### Test client

```haskell
client <- Sdk.testSdk testopts sdkopts
```

`testSdk :: Value -> Value -> IO Client` constructs a test-mode client with
mock transport (`testSdk0 :: IO Client` for the no-argument form). Pass
`VNoval` for defaults.

### Client functions

| Function | Signature | Description |
| --- | --- | --- |
| `newSdk` | `Value -> IO Client` | Construct a live client from options. |
| `newSdk0` | `IO Client` | Construct a live client with defaults. |
| `testSdk` | `Value -> Value -> IO Client` | Construct a test-mode client. |
| `prepare` | `Client -> Value -> IO Value` | Build an HTTP request definition without sending. Raises on error. |
| `direct` | `Client -> Value -> IO Value` | Build and send an HTTP request. Returns a result `Value` (branch on `ok`). |
| `convert` | `Client -> Value -> IO Entity` | Create a Convert entity instance. |
| `embed` | `Client -> Value -> IO Entity` | Create an Embed entity instance. |
| `ephemeral_key` | `Client -> Value -> IO Entity` | Create an EphemeralKey entity instance. |
| `model` | `Client -> Value -> IO Entity` | Create a Model entity instance. |

### Entity interface

All entities share the same record interface (fields of the `Entity` type).

| Field | Signature | Description |
| --- | --- | --- |
| `eList` | `Value -> Value -> IO [Entity]` | List entities matching the criteria. Resolves to one entity per record. Raises on error. |
| `eCreate` | `Value -> Value -> IO Entity` | Create a new entity. Resolves to the entity. Raises on error. |
| `eDataGet` | `IO Value` | Get entity data. |
| `eDataSet` | `Value -> IO ()` | Set entity data. |
| `eStream` | `String -> Value -> Value -> IO [Value]` | Run an op as a lazy stream of items. |
| `eMake` | `IO Entity` | Create a new instance with the same options. |
| `eName` | `String` | The entity name. |

### Result shape

Entity operations resolve to the ENTITY, not the raw record — `eList` to
one entity per record — and raise on error. The record is reached through
`eDataGet`, which returns the entity's data container. `eRemove` resolves to
the entity marked deleted (`eDeleted`); it keeps the data it held. Wrap calls
in `Control.Exception.try` to handle failures.

The `direct` escape hatch never raises — it returns a result `Value`
you branch on via its `ok` field (read with `getp result "ok"`):

| Key | Type | Description |
| --- | --- | --- |
| `ok` | `Bool` | `True` if the HTTP status is 2xx. |
| `status` | `Int` | HTTP status code. |
| `headers` | `Value` | Response headers. |
| `data` | `Value` | Parsed JSON response body. |

On error, `ok` is `False` and `err` carries the error value.

### Entities

#### Convert

| Field | Description |
| --- | --- |
| `bridge_model` | Embed model used to vectorise the text before translation. |
| `embeddings` | Translated vectors, in the target model's dimension. |
| `source_model` | Model space the supplied vectors are currently in. |
| `target_model` | Model space to translate into. |
| `texts` | Texts to embed and translate. |

Operations: Create.

API path: `/v1/convert`

#### Embed

| Field | Description |
| --- | --- |
| `embeddings` | One vector per input text, in input order. |
| `model` | Model that produced the vectors. |
| `texts` | Texts to embed. |

Operations: Create.

API path: `/v1/embed`

#### EphemeralKey

| Field | Description |
| --- | --- |
| `dailyLimit` | Calls permitted per day. |
| `dailyUsed` | Calls already used today. |
| `key` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | When the daily allowance resets. |

Operations: Create.

API path: `/v1/ephemeral/key`

#### Model

| Field | Description |
| --- | --- |
| `eval` | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | Hardware backend, e.g. |
| `modelCard` | Convert models only: training provenance and architecture detail. |
| `modelType` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | Model identifier used in requests. |
| `sequenceLen` | Embed models only: maximum input sequence length. |
| `sourceDim` | Convert models only: source vector dimension. |
| `sourceModel` | Convert models only: the source model space. |
| `targetDim` | Dimension of the produced vectors. |
| `targetModel` | The model space produced. |

Operations: List.

API path: `/v1/models`



## Entities


### Convert

Create an instance: `convert <- Sdk.convert sdk VNoval`

#### Operations

| Method | Description |
| --- | --- |
| `eCreate ent data ctrl` | Create a new entity with the given data. Resolves to the entity. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `bridge_model` | `String` | Embed model used to vectorise the text before translation. |
| `embeddings` | `[Value]` | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Model space to translate into. |
| `texts` | `[Value]` | Texts to embed and translate. |

#### Example: Create

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
  convert <- Sdk.eCreate ent d ctrl
  convertData <- Sdk.eDataGet convert
```


### Embed

Create an instance: `embed <- Sdk.embed sdk VNoval`

#### Operations

| Method | Description |
| --- | --- |
| `eCreate ent data ctrl` | Create a new entity with the given data. Resolves to the entity. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `[Value]` | One vector per input text, in input order. |
| `model` | `String` | Model that produced the vectors. |
| `texts` | `[Value]` | Texts to embed. |

#### Example: Create

```haskell
  ent <- Sdk.embed sdk VNoval
  d <- jo
    [ ("embeddings", VNoval)   -- [Value]
    , ("model", VStr "example_model")   -- String
    , ("texts", VNoval)   -- [Value]
    ]
  ctrl <- emptyMap
  embed <- Sdk.eCreate ent d ctrl
  embedData <- Sdk.eDataGet embed
```


### EphemeralKey

Create an instance: `ephemeral_key <- Sdk.ephemeral_key sdk VNoval`

#### Operations

| Method | Description |
| --- | --- |
| `eCreate ent data ctrl` | Create a new entity with the given data. Resolves to the entity. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `dailyLimit` | `Int` | Calls permitted per day. |
| `dailyUsed` | `Int` | Calls already used today. |
| `key` | `String` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | When the daily allowance resets. |

#### Example: Create

```haskell
  ent <- Sdk.ephemeral_key sdk VNoval
  d <- jo
    [ ("dailyLimit", VNum 1)   -- Int
    , ("dailyUsed", VNum 1)   -- Int
    , ("key", VStr "example_key")   -- String
    , ("resetsAt", VStr "example_resetsAt")   -- String
    ]
  ctrl <- emptyMap
  ephemeral_key <- Sdk.eCreate ent d ctrl
  ephemeral_keyData <- Sdk.eDataGet ephemeral_key
```


### Model

Create an instance: `model <- Sdk.model sdk VNoval`

#### Operations

| Method | Description |
| --- | --- |
| `eList ent match ctrl` | List entities, optionally matching the given criteria. Resolves to one entity per record. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `eval` | `Value` | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | Hardware backend, e.g. |
| `modelCard` | `Value` | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Model identifier used in requests. |
| `sequenceLen` | `Int` | Embed models only: maximum input sequence length. |
| `sourceDim` | `Int` | Convert models only: source vector dimension. |
| `sourceModel` | `String` | Convert models only: the source model space. |
| `targetDim` | `Int` | Dimension of the produced vectors. |
| `targetModel` | `String` | The model space produced. |

#### Example: List

```haskell
  ent <- Sdk.model sdk VNoval
  match <- emptyMap
  ctrl <- emptyMap
  -- One ENTITY per record.
  models <- Sdk.eList ent match ctrl
  modelDatas <- mapM Sdk.eDataGet models
```

## Features

This SDK ships 18 optional features. Each is **inactive until you
switch it on**, so an SDK you have not configured behaves exactly as if none of
them existed — no retries, no cache, no logging, no measurable overhead.

Activate a feature by name in the client options, alongside the options shown
above:

| Feature | What it does |
|---|---|
| [`audit`](#audit) | Structured audit trail of operations |
| [`cache`](#cache) | Response caching for safe read requests |
| [`clienttrack`](#clienttrack) | Client identity and per-request correlation headers |
| [`cost`](#cost) | Cost tracking and spend budget for API calls |
| [`debug`](#debug) | Request/response capture ring buffer for debugging |
| [`idempotency`](#idempotency) | Idempotency keys for safe retries of mutating operations |
| [`log`](#log) | Structured request and response logging |
| [`metrics`](#metrics) | Statistics capture: per-operation counters and latency |
| [`netsim`](#netsim) | Network behaviour simulation for offline testing (latency, failures, outages) |
| [`paging`](#paging) | Pagination signals for list operations |
| [`proxy`](#proxy) | Outbound HTTP(S) proxy routing |
| [`ratelimit`](#ratelimit) | Client-side rate limiting via a token bucket |
| [`rbac`](#rbac) | Client-side role/permission enforcement |
| [`retry`](#retry) | Automatic retry of transient failures with exponential backoff |
| [`streaming`](#streaming) | Incremental streaming of list results via async iteration |
| [`telemetry`](#telemetry) | Distributed tracing spans with W3C trace-context propagation |
| [`test`](#test) | In-memory mock transport for testing without a live server |
| [`timeout`](#timeout) | Per-request timeout with transport abort |

> **Order matters for `cache`, `cost`, `netsim`, `proxy`, `ratelimit`, `retry`, `timeout`.** These wrap the
> transport, so each one wraps whatever is already installed: the order you
> activate them in IS the nesting order. Activating them as an ordered list
> rather than a map is what fixes that order.

### audit

Structured audit trail of operations.

| Option | Default |
|---|---|
| `active` | `false` |
| `actor` | `'anonymous'` |
| `max` | `1000` |

Set `feature.audit.active` to enable it, then override any of the options above.

### cache

Response caching for safe read requests.

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `256` |
| `methods` | `['GET']` |
| `ttl` | `5000` |

Set `feature.cache.active` to enable it, then override any of the options above.

`cache` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### clienttrack

Client identity and per-request correlation headers.

| Option | Default |
|---|---|
| `active` | `false` |
| `clientVersion` | `'0.0.1'` |

Set `feature.clienttrack.active` to enable it, then override any of the options above.

### cost

Cost tracking and spend budget for API calls.

| Option | Default |
|---|---|
| `active` | `false` |
| `budget` | `0` |
| `currency` | `'USD'` |
| `header` | `''` |
| `onBudget` | `'warn'` |
| `path` | `''` |
| `perUnit` | `0` |
| `rates` | `{}` |
| `unit` | `0` |

Set `feature.cost.active` to enable it, then override any of the options above.

`cost` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### debug

Request/response capture ring buffer for debugging.

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `100` |
| `redact` | `['authorization', 'cookie', 'set-cookie', 'api-key', 'apikey', 'x-api-key', 'idempotency-key']` |

Set `feature.debug.active` to enable it, then override any of the options above.

### idempotency

Idempotency keys for safe retries of mutating operations.

| Option | Default |
|---|---|
| `active` | `false` |
| `header` | `'Idempotency-Key'` |
| `methods` | `['POST', 'PUT', 'PATCH', 'DELETE']` |
| `ops` | `['create', 'update', 'remove']` |

Set `feature.idempotency.active` to enable it, then override any of the options above.

### log

Structured request and response logging.

| Option | Default |
|---|---|
| `active` | `true` |

Set `feature.log.active` to enable it, then override any of the options above.

### metrics

Statistics capture: per-operation counters and latency.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.metrics.active` to enable it, then override any of the options above.

### netsim

Network behaviour simulation for offline testing (latency, failures, outages).

| Option | Default |
|---|---|
| `active` | `false` |
| `errorTimes` | `0` |
| `failEvery` | `0` |
| `failRate` | `0` |
| `failStatus` | `503` |
| `failTimes` | `0` |
| `latency` | `0` |
| `offline` | `false` |
| `rateLimitTimes` | `0` |
| `retryAfter` | `0` |
| `seed` | `1` |

Set `feature.netsim.active` to enable it, then override any of the options above.

`netsim` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### paging

Pagination signals for list operations.

| Option | Default |
|---|---|
| `active` | `false` |
| `afterVar` | `'after'` |
| `cursorParam` | `'cursor'` |
| `firstVar` | `'first'` |
| `limitParam` | `'limit'` |
| `pageParam` | `'page'` |
| `startPage` | `1` |

Set `feature.paging.active` to enable it, then override any of the options above.

### proxy

Outbound HTTP(S) proxy routing.

| Option | Default |
|---|---|
| `active` | `false` |
| `fromEnv` | `false` |
| `noProxy` | `[]` |
| `url` | `''` |

Set `feature.proxy.active` to enable it, then override any of the options above.

`proxy` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### ratelimit

Client-side rate limiting via a token bucket.

| Option | Default |
|---|---|
| `active` | `false` |
| `burst` | `5` |
| `rate` | `5` |

Set `feature.ratelimit.active` to enable it, then override any of the options above.

`ratelimit` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### rbac

Client-side role/permission enforcement.

| Option | Default |
|---|---|
| `active` | `false` |
| `deny` | `false` |
| `permissions` | `[]` |
| `rules` | `{}` |

Set `feature.rbac.active` to enable it, then override any of the options above.

### retry

Automatic retry of transient failures with exponential backoff.

| Option | Default |
|---|---|
| `active` | `false` |
| `factor` | `2` |
| `maxDelay` | `2000` |
| `minDelay` | `50` |
| `retries` | `2` |
| `statuses` | `[408, 425, 429, 500, 502, 503, 504]` |

Set `feature.retry.active` to enable it, then override any of the options above.

`retry` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### streaming

Incremental streaming of list results via async iteration.

| Option | Default |
|---|---|
| `active` | `false` |
| `chunkDelay` | `0` |
| `chunkSize` | `0` |

Set `feature.streaming.active` to enable it, then override any of the options above.

### telemetry

Distributed tracing spans with W3C trace-context propagation.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.telemetry.active` to enable it, then override any of the options above.

### test

In-memory mock transport for testing without a live server.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.test.active` to enable it, then override any of the options above.

### timeout

Per-request timeout with transport abort.

| Option | Default |
|---|---|
| `active` | `false` |
| `ms` | `30000` |

Set `feature.timeout.active` to enable it, then override any of the options above.

`timeout` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.


## Advanced

> The sections above cover everyday use. The material below explains the
> SDK's internals — useful when extending it with custom features, but not
> needed for normal use.

### The operation pipeline

Every entity operation follows a six-stage pipeline. Each stage fires a
feature hook before executing:

```
PrePoint → PreSpec → PreRequest → PreResponse → PreResult → PreDone
```

- **PrePoint**: Resolves which API endpoint to call based on the
  operation name and entity configuration.
- **PreSpec**: Builds the HTTP spec — URL, method, headers, body —
  from the resolved point and the caller's parameters.
- **PreRequest**: Sends the HTTP request. Features can intercept here
  to replace the transport (as TestFeature does with mocks).
- **PreResponse**: Parses the raw HTTP response.
- **PreResult**: Extracts the business data from the parsed response.
- **PreDone**: Final stage before returning to the caller. Entity
  state (match, data) is updated here.

If any stage errors, the pipeline short-circuits and the error surfaces
to the caller — see [Error handling](#error-handling) for how that looks
in this language.

### Features and hooks

Features are the extension mechanism. A feature is an object with a
`hooks` map. Each hook key is a pipeline stage name, and the value is
a function that receives the context.

The SDK ships with built-in features:

- **AuditFeature**: Structured audit trail of operations
- **CacheFeature**: Response caching for safe read requests
- **ClienttrackFeature**: Client identity and per-request correlation headers
- **CostFeature**: Cost tracking and spend budget for API calls
- **DebugFeature**: Request/response capture ring buffer for debugging
- **IdempotencyFeature**: Idempotency keys for safe retries of mutating operations
- **LogFeature**: Structured request and response logging
- **MetricsFeature**: Statistics capture: per-operation counters and latency
- **NetsimFeature**: Network behaviour simulation for offline testing (latency, failures, outages)
- **PagingFeature**: Pagination signals for list operations
- **ProxyFeature**: Outbound HTTP(S) proxy routing
- **RatelimitFeature**: Client-side rate limiting via a token bucket
- **RbacFeature**: Client-side role/permission enforcement
- **RetryFeature**: Automatic retry of transient failures with exponential backoff
- **StreamingFeature**: Incremental streaming of list results via async iteration
- **TelemetryFeature**: Distributed tracing spans with W3C trace-context propagation
- **TestFeature**: In-memory mock transport for testing without a live server
- **TimeoutFeature**: Per-request timeout with transport abort

Features are initialized in order. Hooks fire in the order features
were added, so later features can override earlier ones.

### Data as struct Values

The Haskell SDK models every API record as the dynamic `Value` type (from
the vendored `VoxgigStruct` module) rather than bespoke Haskell records.
This mirrors the dynamic nature of the API and keeps the SDK flexible — no
new datatypes or code generation are needed when the API schema changes.

Build request maps with `jo [(key, value)]` and read fields back with
`getp value "field"`; scalars are the `VStr` / `VNum` / `VBool`
constructors, and `VNoval` stands for an absent property.

### Module structure

```
haskell/
├── src/
│   ├── VoxgigStruct.hs   -- vendored dependency-free struct library (Value)
│   ├── Vregex.hs         -- vendored regex support
│   ├── SdkTypes.hs       -- core types (Client, Entity, Feature)
│   ├── SdkHelpers.hs     -- helper functions (jo, getp, ...)
│   ├── SdkRuntime.hs     -- the generic operation pipeline
│   ├── SdkFeatures.hs    -- built-in features + makeEntity
│   ├── SdkConfig.hs      -- generated API configuration + feature factory
│   └── SdkClient.hs      -- generated public client (newSdk, entity accessors)
├── test/                 -- test suites
├── Makefile              -- stock-GHC build/test (no third-party deps)
└── univec-sdk.cabal      -- package manifest (for Hackage)
```

The public module (`SdkClient`) exports the SDK constructors (`newSdk`,
`testSdk`) and one accessor per entity. Import `VoxgigStruct` for the
`Value` constructors and `SdkHelpers` for `jo` / `getp`.

### Entity state

Entity instances are stateful. After a successful `list`, the entity
stores the returned data and match criteria internally. Subsequent
calls on the same instance can rely on this state.

```ts
const model = client.Model()
await model.list()

// model.data() now returns the model data from the last `list`
// model.match() returns the last match criteria
```

Call `make()` to create a fresh instance with the same configuration
but no stored state.

### Direct vs entity access

The entity interface handles URL construction, parameter placement,
and response parsing automatically. Use it for standard CRUD operations.

The `direct` method gives full control over the HTTP request. Use it
for non-standard endpoints, bulk operations, or any path not modelled
as an entity. The `prepare` method is useful for debugging — it
shows exactly what `direct` would send.


## Full Reference

See [REFERENCE.md](REFERENCE.md) for complete API reference
documentation including all method signatures, entity field schemas,
and detailed usage examples.
