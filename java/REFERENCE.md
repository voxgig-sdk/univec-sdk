# Univec Java SDK Reference

Complete API reference for the Univec Java SDK.


## UnivecSDK

### Constructor

```java
UnivecSDK client = new UnivecSDK(options);
```

Create a new SDK client instance. `options` is a `Map<String, Object>`.

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

```java
UnivecSDK client = UnivecSDK.testSDK(null, null);
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
`Map<String, Object>` with `ok`, `status`, `headers`, and `data` (or
`err` on failure). This escape hatch never raises — branch on
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

**Returns:** `Map<String, Object>`

#### `prepare(fetchargs) -> Map`

Prepare a fetch definition without sending. Returns the `fetchdef` and raises on error.


---

## Convert

```java
SdkEntity convert = client.convert(null);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `List<Object>` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Yes | Model space to translate into. |
| `texts` | `List<Object>` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata, ctrl) -> Object`

Create a new entity with the given data. Returns the created entity data and raises on error.

```java
Object result = client.convert(null).create(Map.of(
    "bridge_model", "example_bridge_model",  // String
    "embeddings", List.of(),  // List<Object>
    "source_model", "example_source_model",  // String
    "target_model", "example_target_model",  // String
    "texts", List.of()  // List<Object>
), null);
```

### Common Methods

#### `data(newdata...) -> Object`

Get or set the entity data.

#### `match(newmatch...) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Convert` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


---

## Embed

```java
SdkEntity embed = client.embed(null);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `List<Object>` | Yes | One vector per input text, in input order. |
| `model` | `String` | Yes | Model that produced the vectors. |
| `texts` | `List<Object>` | Yes | Texts to embed. |

### Operations

#### `create(reqdata, ctrl) -> Object`

Create a new entity with the given data. Returns the created entity data and raises on error.

```java
Object result = client.embed(null).create(Map.of(
    "embeddings", List.of(),  // List<Object>
    "model", "example_model",  // String
    "texts", List.of()  // List<Object>
), null);
```

### Common Methods

#### `data(newdata...) -> Object`

Get or set the entity data.

#### `match(newmatch...) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `Embed` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


---

## EphemeralKey

```java
SdkEntity ephemeralKey = client.ephemeralKey(null);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `Long` | Yes | Calls permitted per day. |
| `dailyUsed` | `Long` | Yes | Calls already used today. |
| `key` | `String` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata, ctrl) -> Object`

Create a new entity with the given data. Returns the created entity data and raises on error.

```java
Object result = client.ephemeralKey(null).create(Map.of(
    "dailyLimit", 1L,  // Long
    "dailyUsed", 1L,  // Long
    "key", "example_key",  // String
    "resetsAt", "example_resetsAt"  // String
), null);
```

### Common Methods

#### `data(newdata...) -> Object`

Get or set the entity data.

#### `match(newmatch...) -> Object`

Get or set the entity match criteria.

#### `make() -> Entity`

Create a new `EphemeralKey` entity instance with the same options.

#### `getName() -> String`

Return the entity name.


---

## Model

```java
SdkEntity model = client.model(null);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Map<String, Object>` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | No | Hardware backend, e.g. |
| `modelCard` | `Map<String, Object>` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Yes | Model identifier used in requests. |
| `sequenceLen` | `Long` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `Long` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String` | No | Convert models only: the source model space. |
| `targetDim` | `Long` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String` | Yes | The model space produced. |

### Operations

#### `list(reqmatch, ctrl) -> Object`

List entities matching the given criteria. The match is optional — call `list(null, null)` to list all records. Returns an aggregate list and raises on error.

```java
Object results = client.model(null).list(null, null);
System.out.println(results);
```

### Common Methods

#### `data(newdata...) -> Object`

Get or set the entity data.

#### `match(newmatch...) -> Object`

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

```java
Map<String, Object> feature = new java.util.LinkedHashMap<>();
feature.put("audit", Map.of("active", true));
feature.put("cache", Map.of("active", true));
feature.put("clienttrack", Map.of("active", true));
feature.put("cost", Map.of("active", true));
feature.put("debug", Map.of("active", true));
feature.put("idempotency", Map.of("active", true));
feature.put("log", Map.of("active", true));
feature.put("metrics", Map.of("active", true));
feature.put("netsim", Map.of("active", true));
feature.put("paging", Map.of("active", true));
feature.put("proxy", Map.of("active", true));
feature.put("ratelimit", Map.of("active", true));
feature.put("rbac", Map.of("active", true));
feature.put("retry", Map.of("active", true));
feature.put("streaming", Map.of("active", true));
feature.put("telemetry", Map.of("active", true));
feature.put("test", Map.of("active", true));
feature.put("timeout", Map.of("active", true));
Map<String, Object> options = new java.util.LinkedHashMap<>();
options.put("feature", feature);
UnivecSDK client = new UnivecSDK(options);
```

