# Univec Kotlin SDK Reference

Complete API reference for the Univec Kotlin SDK.


## UnivecSDK

### Constructor

```kotlin
val client = UnivecSDK(options)
```

Create a new SDK client instance. `options` is a `MutableMap<String, Any?>`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `Map` | SDK configuration options. |
| `options["apikey"]` | `String` | API key for authentication. |
| `options["base"]` | `String` | Base URL for API requests. |
| `options["prefix"]` | `String` | URL prefix appended after base. |
| `options["suffix"]` | `String` | URL suffix appended after path. |
| `options["headers"]` | `Map` | Custom headers for all requests. |
| `options["feature"]` | `Map` | Feature configuration. |
| `options["system"]` | `Map` | System overrides (e.g. custom fetch). |


### Static Methods

#### `UnivecSDK.testSDK(testopts, sdkopts)`

Create a test client with mock features active. Both arguments may be `null`.

```kotlin
val client = UnivecSDK.testSDK(null, null)
```


### Instance Methods

#### `convert(entopts)`

Create a new `Convert` entity instance (returns `SdkEntity`). Pass
`null` for no initial options.

#### `embed(entopts)`

Create a new `Embed` entity instance (returns `SdkEntity`). Pass
`null` for no initial options.

#### `ephemeralKey(entopts)`

Create a new `EphemeralKey` entity instance (returns `SdkEntity`). Pass
`null` for no initial options.

#### `model(entopts)`

Create a new `Model` entity instance (returns `SdkEntity`). Pass
`null` for no initial options.

#### `optionsMap() -> MutableMap`

Return a deep copy of the current SDK options.

#### `getUtility() -> Utility`

Return a copy of the SDK utility object.

#### `direct(fetchargs) -> MutableMap`

Make a direct HTTP request to any API endpoint. Returns a result
`MutableMap<String, Any?>` with `ok`, `status`, `headers`, and `data`
(or `err` on failure). This escape hatch never raises — branch on
`result["ok"]`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs["path"]` | `String` | URL path with optional `{param}` placeholders. |
| `fetchargs["method"]` | `String` | HTTP method (default: `"GET"`). |
| `fetchargs["params"]` | `Map` | Path parameter values. |
| `fetchargs["query"]` | `Map` | Query string parameters. |
| `fetchargs["headers"]` | `Map` | Request headers (merged with defaults). |
| `fetchargs["body"]` | `Any?` | Request body (maps are JSON-serialized). |

**Returns:** `MutableMap<String, Any?>`

#### `prepare(fetchargs) -> MutableMap`

Prepare a fetch definition without sending. Returns the `fetchdef` and raises on error.


---

## Convert

```kotlin
val convert = client.convert(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String?` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `List<Any?>?` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String?` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String?` | Yes | Model space to translate into. |
| `texts` | `List<Any?>?` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata, ctrl) -> Any?`

Create a new entity with the given data. Returns the created entity data and raises on error.

```kotlin
val result = client.convert(null).create(mutableMapOf<String, Any?>(
    "bridge_model" to "example_bridge_model",  // String?
    "embeddings" to listOf<Any?>(),  // List<Any?>?
    "source_model" to "example_source_model",  // String?
    "target_model" to "example_target_model",  // String?
    "texts" to listOf<Any?>()  // List<Any?>?
), null)
```

### Common Methods

#### `data(vararg newdata) -> Any?`

Get or set the entity data.

#### `match(vararg newmatch) -> Any?`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Convert` entity instance with the same options.

#### `name -> String`

The entity name (read-only property).


---

## Embed

```kotlin
val embed = client.embed(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `List<Any?>?` | Yes | One vector per input text, in input order. |
| `model` | `String?` | Yes | Model that produced the vectors. |
| `texts` | `List<Any?>?` | Yes | Texts to embed. |

### Operations

#### `create(reqdata, ctrl) -> Any?`

Create a new entity with the given data. Returns the created entity data and raises on error.

```kotlin
val result = client.embed(null).create(mutableMapOf<String, Any?>(
    "embeddings" to listOf<Any?>(),  // List<Any?>?
    "model" to "example_model",  // String?
    "texts" to listOf<Any?>()  // List<Any?>?
), null)
```

### Common Methods

#### `data(vararg newdata) -> Any?`

Get or set the entity data.

#### `match(vararg newmatch) -> Any?`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Embed` entity instance with the same options.

#### `name -> String`

The entity name (read-only property).


---

## EphemeralKey

```kotlin
val ephemeralKey = client.ephemeralKey(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `Long?` | Yes | Calls permitted per day. |
| `dailyUsed` | `Long?` | Yes | Calls already used today. |
| `key` | `String?` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String?` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata, ctrl) -> Any?`

Create a new entity with the given data. Returns the created entity data and raises on error.

```kotlin
val result = client.ephemeralKey(null).create(mutableMapOf<String, Any?>(
    "dailyLimit" to 1L,  // Long?
    "dailyUsed" to 1L,  // Long?
    "key" to "example_key",  // String?
    "resetsAt" to "example_resetsAt"  // String?
), null)
```

### Common Methods

#### `data(vararg newdata) -> Any?`

Get or set the entity data.

#### `match(vararg newmatch) -> Any?`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `EphemeralKey` entity instance with the same options.

#### `name -> String`

The entity name (read-only property).


---

## Model

```kotlin
val model = client.model(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Map<String, Any?>?` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String?` | No | Hardware backend, e.g. |
| `modelCard` | `Map<String, Any?>?` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String?` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String?` | Yes | Model identifier used in requests. |
| `sequenceLen` | `Long?` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `Long?` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String?` | No | Convert models only: the source model space. |
| `targetDim` | `Long?` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String?` | Yes | The model space produced. |

### Operations

#### `list(reqmatch, ctrl) -> Any?`

List entities matching the given criteria. The match is optional — call `list(null, null)` to list all records. Returns an aggregate list and raises on error.

```kotlin
val results = client.model(null).list(null, null)
println(results)
```

### Common Methods

#### `data(vararg newdata) -> Any?`

Get or set the entity data.

#### `match(vararg newmatch) -> Any?`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Model` entity instance with the same options.

#### `name -> String`

The entity name (read-only property).


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

```kotlin
val feature = mutableMapOf<String, Any?>(
    "audit" to mapOf("active" to true),
    "cache" to mapOf("active" to true),
    "clienttrack" to mapOf("active" to true),
    "cost" to mapOf("active" to true),
    "debug" to mapOf("active" to true),
    "idempotency" to mapOf("active" to true),
    "log" to mapOf("active" to true),
    "metrics" to mapOf("active" to true),
    "netsim" to mapOf("active" to true),
    "paging" to mapOf("active" to true),
    "proxy" to mapOf("active" to true),
    "ratelimit" to mapOf("active" to true),
    "rbac" to mapOf("active" to true),
    "retry" to mapOf("active" to true),
    "streaming" to mapOf("active" to true),
    "telemetry" to mapOf("active" to true),
    "test" to mapOf("active" to true),
    "timeout" to mapOf("active" to true),
)
val client = UnivecSDK(mutableMapOf<String, Any?>("feature" to feature))
```

