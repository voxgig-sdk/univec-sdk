# Univec Scala SDK Reference

Complete API reference for the Univec Scala SDK.


## UnivecSDK

### Constructor

```scala
val client = new UnivecSDK(options)
```

Create a new SDK client instance. `options` is a `java.util.Map[String, Object]`.

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

```scala
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

#### `optionsMap() -> Map`

Return a deep copy of the current SDK options.

#### `getUtility() -> Utility`

Return a copy of the SDK utility object.

#### `direct(fetchargs) -> Map`

Make a direct HTTP request to any API endpoint. Returns a result
`java.util.Map[String, Object]` with `ok`, `status`, `headers`, and
`data` (or `err` on failure). This escape hatch never raises — branch on
`result.get("ok")`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs["path"]` | `String` | URL path with optional `{param}` placeholders. |
| `fetchargs["method"]` | `String` | HTTP method (default: `"GET"`). |
| `fetchargs["params"]` | `Map` | Path parameter values. |
| `fetchargs["query"]` | `Map` | Query string parameters. |
| `fetchargs["headers"]` | `Map` | Request headers (merged with defaults). |
| `fetchargs["body"]` | `Object` | Request body (maps are JSON-serialized). |

**Returns:** `java.util.Map[String, Object]`

#### `prepare(fetchargs) -> Map`

Prepare a fetch definition without sending. Returns the `fetchdef` and raises on error.


---

## Convert

```scala
val convert = client.convert(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `java.util.List[Object]` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Yes | Model space to translate into. |
| `texts` | `java.util.List[Object]` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata, ctrl) -> Object`

Create a new entity with the given data. Returns the created entity data and raises on error.

```scala
val result = client.convert(null).create(java.util.Map.of(
    "bridge_model", "example_bridge_model",  // String
    "embeddings", java.util.List.of(),  // java.util.List[Object]
    "source_model", "example_source_model",  // String
    "target_model", "example_target_model",  // String
    "texts", java.util.List.of()  // java.util.List[Object]
), null)
```

### Common Methods

#### `data(newdata*) -> Object`

Get or set the entity data.

#### `matchArgs(newmatch*) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Convert` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


---

## Embed

```scala
val embed = client.embed(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `java.util.List[Object]` | Yes | One vector per input text, in input order. |
| `model` | `String` | Yes | Model that produced the vectors. |
| `texts` | `java.util.List[Object]` | Yes | Texts to embed. |

### Operations

#### `create(reqdata, ctrl) -> Object`

Create a new entity with the given data. Returns the created entity data and raises on error.

```scala
val result = client.embed(null).create(java.util.Map.of(
    "embeddings", java.util.List.of(),  // java.util.List[Object]
    "model", "example_model",  // String
    "texts", java.util.List.of()  // java.util.List[Object]
), null)
```

### Common Methods

#### `data(newdata*) -> Object`

Get or set the entity data.

#### `matchArgs(newmatch*) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Embed` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


---

## EphemeralKey

```scala
val ephemeralKey = client.ephemeralKey(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `java.lang.Long` | Yes | Calls permitted per day. |
| `dailyUsed` | `java.lang.Long` | Yes | Calls already used today. |
| `key` | `String` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata, ctrl) -> Object`

Create a new entity with the given data. Returns the created entity data and raises on error.

```scala
val result = client.ephemeralKey(null).create(java.util.Map.of(
    "dailyLimit", 1L,  // java.lang.Long
    "dailyUsed", 1L,  // java.lang.Long
    "key", "example_key",  // String
    "resetsAt", "example_resetsAt"  // String
), null)
```

### Common Methods

#### `data(newdata*) -> Object`

Get or set the entity data.

#### `matchArgs(newmatch*) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `EphemeralKey` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


---

## Model

```scala
val model = client.model(null)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `java.util.Map[String, Object]` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | No | Hardware backend, e.g. |
| `modelCard` | `java.util.Map[String, Object]` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Yes | Model identifier used in requests. |
| `sequenceLen` | `java.lang.Long` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `java.lang.Long` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String` | No | Convert models only: the source model space. |
| `targetDim` | `java.lang.Long` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String` | Yes | The model space produced. |

### Operations

#### `list(reqmatch, ctrl) -> Object`

List entities matching the given criteria. The match is optional — call `list(null, null)` to list all records. Returns an aggregate list and raises on error.

```scala
val results = client.model(null).list(null, null)
println(results)
```

### Common Methods

#### `data(newdata*) -> Object`

Get or set the entity data.

#### `matchArgs(newmatch*) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Model` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


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

```scala
val feature = new java.util.LinkedHashMap[String, Object]()
feature.put("audit", java.util.Map.of("active", true))
feature.put("cache", java.util.Map.of("active", true))
feature.put("clienttrack", java.util.Map.of("active", true))
feature.put("cost", java.util.Map.of("active", true))
feature.put("debug", java.util.Map.of("active", true))
feature.put("idempotency", java.util.Map.of("active", true))
feature.put("log", java.util.Map.of("active", true))
feature.put("metrics", java.util.Map.of("active", true))
feature.put("netsim", java.util.Map.of("active", true))
feature.put("paging", java.util.Map.of("active", true))
feature.put("proxy", java.util.Map.of("active", true))
feature.put("ratelimit", java.util.Map.of("active", true))
feature.put("rbac", java.util.Map.of("active", true))
feature.put("retry", java.util.Map.of("active", true))
feature.put("streaming", java.util.Map.of("active", true))
feature.put("telemetry", java.util.Map.of("active", true))
feature.put("test", java.util.Map.of("active", true))
feature.put("timeout", java.util.Map.of("active", true))
val options = new java.util.LinkedHashMap[String, Object]()
options.put("feature", feature)
val client = new UnivecSDK(options)
```

