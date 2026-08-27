# Univec C++ SDK Reference

Complete API reference for the Univec C++ SDK.


## UnivecSDK

### Constructor

```cpp
#include "core/sdk.hpp"

using namespace sdk;

auto client = std::make_shared<UnivecSDK>(options);
```

Create a new SDK client instance. `options` is an `sdk::Value` map.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `Value` | SDK configuration options (a map). |
| `options["apikey"]` | `std::string` | API key for authentication. |
| `options["base"]` | `std::string` | Base URL for API requests. |
| `options["prefix"]` | `std::string` | URL prefix appended after base. |
| `options["suffix"]` | `std::string` | URL suffix appended after path. |
| `options["headers"]` | `Value` | Custom headers for all requests. |
| `options["feature"]` | `Value` | Feature configuration. |
| `options["system"]` | `Value` | System overrides. |


### Static Methods

#### `UnivecSDK::testSDK(testopts, sdkopts)`

Create a test client with mock features active. Both arguments may be
`Value::undef()`; a no-arg overload is also provided.

```cpp
auto client = UnivecSDK::testSDK();
```


### Instance Methods

#### `convert(entopts = Value::undef()) -> std::shared_ptr<ConvertEntity>`

Create a new `ConvertEntity` instance bound to this client.

#### `embed(entopts = Value::undef()) -> std::shared_ptr<EmbedEntity>`

Create a new `EmbedEntity` instance bound to this client.

#### `ephemeral_key(entopts = Value::undef()) -> std::shared_ptr<EphemeralKeyEntity>`

Create a new `EphemeralKeyEntity` instance bound to this client.

#### `model(entopts = Value::undef()) -> std::shared_ptr<ModelEntity>`

Create a new `ModelEntity` instance bound to this client.

#### `optionsMap() -> Value`

Return a deep copy of the current SDK options.

#### `getUtility() -> UtilityPtr`

Return a copy of the SDK utility object.

#### `direct(fetchargs) -> Value`

Make a direct HTTP request to any API endpoint. Returns a result `Value` with `ok`, `status`, `headers`, and `data` (or `err` on failure). This escape hatch never throws — branch on `getp(result, "ok")`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs["path"]` | `std::string` | URL path with optional `{param}` placeholders. |
| `fetchargs["method"]` | `std::string` | HTTP method (default: `"GET"`). |
| `fetchargs["params"]` | `Value` | Path parameter values. |
| `fetchargs["query"]` | `Value` | Query string parameters. |
| `fetchargs["headers"]` | `Value` | Request headers (merged with defaults). |
| `fetchargs["body"]` | `Value` | Request body (maps are JSON-serialized). |

**Returns:** `Value` (result map)

#### `prepare(fetchargs) -> Value`

Prepare a fetch definition without sending. Returns the `fetchdef` and throws on error.


---

## ConvertEntity

```cpp
auto convert = client->convert();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `std::string` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `std::vector<Value>` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `std::string` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `std::string` | Yes | Model space to translate into. |
| `texts` | `std::vector<Value>` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata, ctrl) -> Value`

Create a new entity with the given data. Returns the created entity data and throws on error.

```cpp
Value result = client->convert()->create(vmap({
    {"bridge_model", Value("example_bridge_model")},  // std::string
    {"embeddings", vlist()},  // std::vector<Value>
    {"source_model", Value("example_source_model")},  // std::string
    {"target_model", Value("example_target_model")},  // std::string
    {"texts", vlist()},  // std::vector<Value>
}), Value::undef());
```

### Common Methods

#### `data(arg = Value::undef()) -> Value`

Get the entity data (no argument) or set it (with a map argument).

#### `match(arg = Value::undef()) -> Value`

Get the entity match criteria (no argument) or set it (with a map argument).

#### `make() -> EntityPtr`

Create a new `ConvertEntity` instance with the same options.

#### `getName() -> std::string`

Return the entity name.


---

## EmbedEntity

```cpp
auto embed = client->embed();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `std::vector<Value>` | Yes | One vector per input text, in input order. |
| `model` | `std::string` | Yes | Model that produced the vectors. |
| `texts` | `std::vector<Value>` | Yes | Texts to embed. |

### Operations

#### `create(reqdata, ctrl) -> Value`

Create a new entity with the given data. Returns the created entity data and throws on error.

```cpp
Value result = client->embed()->create(vmap({
    {"embeddings", vlist()},  // std::vector<Value>
    {"model", Value("example_model")},  // std::string
    {"texts", vlist()},  // std::vector<Value>
}), Value::undef());
```

### Common Methods

#### `data(arg = Value::undef()) -> Value`

Get the entity data (no argument) or set it (with a map argument).

#### `match(arg = Value::undef()) -> Value`

Get the entity match criteria (no argument) or set it (with a map argument).

#### `make() -> EntityPtr`

Create a new `EmbedEntity` instance with the same options.

#### `getName() -> std::string`

Return the entity name.


---

## EphemeralKeyEntity

```cpp
auto ephemeral_key = client->ephemeral_key();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `int64_t` | Yes | Calls permitted per day. |
| `dailyUsed` | `int64_t` | Yes | Calls already used today. |
| `key` | `std::string` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `std::string` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata, ctrl) -> Value`

Create a new entity with the given data. Returns the created entity data and throws on error.

```cpp
Value result = client->ephemeral_key()->create(vmap({
    {"dailyLimit", Value(1)},  // int64_t
    {"dailyUsed", Value(1)},  // int64_t
    {"key", Value("example_key")},  // std::string
    {"resetsAt", Value("example_resetsAt")},  // std::string
}), Value::undef());
```

### Common Methods

#### `data(arg = Value::undef()) -> Value`

Get the entity data (no argument) or set it (with a map argument).

#### `match(arg = Value::undef()) -> Value`

Get the entity match criteria (no argument) or set it (with a map argument).

#### `make() -> EntityPtr`

Create a new `EphemeralKeyEntity` instance with the same options.

#### `getName() -> std::string`

Return the entity name.


---

## ModelEntity

```cpp
auto model = client->model();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `std::map<std::string, Value>` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `std::string` | No | Hardware backend, e.g. |
| `modelCard` | `std::map<std::string, Value>` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `std::string` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `std::string` | Yes | Model identifier used in requests. |
| `sequenceLen` | `int64_t` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `int64_t` | No | Convert models only: source vector dimension. |
| `sourceModel` | `std::string` | No | Convert models only: the source model space. |
| `targetDim` | `int64_t` | Yes | Dimension of the produced vectors. |
| `targetModel` | `std::string` | Yes | The model space produced. |

### Operations

#### `list(reqmatch, ctrl) -> Value`

List entities matching the given criteria. The match is optional — pass `Value::undef()` to list all records. Returns a Value list and throws on error.

```cpp
Value results = client->model()->list(Value::undef(), Value::undef());
for (const auto& model : *results.as_list()) {
  std::cout << Struct::jsonify(model) << std::endl;
}
```

### Common Methods

#### `data(arg = Value::undef()) -> Value`

Get the entity data (no argument) or set it (with a map argument).

#### `match(arg = Value::undef()) -> Value`

Get the entity match criteria (no argument) or set it (with a map argument).

#### `make() -> EntityPtr`

Create a new `ModelEntity` instance with the same options.

#### `getName() -> std::string`

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

```cpp
auto client = std::make_shared<UnivecSDK>(vmap({
    {"feature", vmap({
        {"audit", vmap({{"active", Value(true)}})},
        {"cache", vmap({{"active", Value(true)}})},
        {"clienttrack", vmap({{"active", Value(true)}})},
        {"cost", vmap({{"active", Value(true)}})},
        {"debug", vmap({{"active", Value(true)}})},
        {"idempotency", vmap({{"active", Value(true)}})},
        {"log", vmap({{"active", Value(true)}})},
        {"metrics", vmap({{"active", Value(true)}})},
        {"netsim", vmap({{"active", Value(true)}})},
        {"paging", vmap({{"active", Value(true)}})},
        {"proxy", vmap({{"active", Value(true)}})},
        {"ratelimit", vmap({{"active", Value(true)}})},
        {"rbac", vmap({{"active", Value(true)}})},
        {"retry", vmap({{"active", Value(true)}})},
        {"streaming", vmap({{"active", Value(true)}})},
        {"telemetry", vmap({{"active", Value(true)}})},
        {"test", vmap({{"active", Value(true)}})},
        {"timeout", vmap({{"active", Value(true)}})},
    })},
}));
```

