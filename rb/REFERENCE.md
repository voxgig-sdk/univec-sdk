# Univec Ruby SDK Reference

Complete API reference for the Univec Ruby SDK.


## UnivecSDK

### Constructor

```ruby
require_relative 'Univec_sdk'

client = UnivecSDK.new(options)
```

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `Hash` | SDK configuration options. |
| `options["apikey"]` | `String` | API key for authentication. |
| `options["base"]` | `String` | Base URL for API requests. |
| `options["prefix"]` | `String` | URL prefix appended after base. |
| `options["suffix"]` | `String` | URL suffix appended after path. |
| `options["headers"]` | `Hash` | Custom headers for all requests. |
| `options["feature"]` | `Hash` | Feature configuration. |
| `options["system"]` | `Hash` | System overrides (e.g. custom fetch). |


### Static Methods

#### `UnivecSDK.test(testopts = nil, sdkopts = nil)`

Create a test client with mock features active. Both arguments may be `nil`.

```ruby
client = UnivecSDK.test
```


### Instance Methods

#### `Convert(data = nil)`

Create a new `Convert` entity instance. Pass `nil` for no initial data.

#### `Embed(data = nil)`

Create a new `Embed` entity instance. Pass `nil` for no initial data.

#### `EphemeralKey(data = nil)`

Create a new `EphemeralKey` entity instance. Pass `nil` for no initial data.

#### `Model(data = nil)`

Create a new `Model` entity instance. Pass `nil` for no initial data.

#### `options_map -> Hash`

Return a deep copy of the current SDK options.

#### `get_utility -> Utility`

Return a copy of the SDK utility object.

#### `direct(fetchargs = {}) -> Hash`

Make a direct HTTP request to any API endpoint. Returns a result hash
(`{ "ok" => ..., "status" => ..., "data" => ..., "err" => ... }`); it
does not raise — inspect `result["ok"]`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs["path"]` | `String` | URL path with optional `{param}` placeholders. |
| `fetchargs["method"]` | `String` | HTTP method (default: `"GET"`). |
| `fetchargs["params"]` | `Hash` | Path parameter values for `{param}` substitution. |
| `fetchargs["query"]` | `Hash` | Query string parameters. |
| `fetchargs["headers"]` | `Hash` | Request headers (merged with defaults). |
| `fetchargs["body"]` | `any` | Request body (hashes are JSON-serialized). |
| `fetchargs["ctrl"]` | `Hash` | Control options (e.g. `{ "explain" => true }`). |

**Returns:** `Hash`

#### `prepare(fetchargs = {}) -> Hash`

Prepare a fetch definition without sending the request. Accepts the
same parameters as `direct()`. Raises on error.

**Returns:** `Hash` (the fetch definition; raises on error)


---

## ConvertEntity

```ruby
convert = client.Convert
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `Array` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Yes | Model space to translate into. |
| `texts` | `Array` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata, ctrl = nil) -> result`

Create a new entity with the given data. Raises on error.

```ruby
result = client.Convert.create({
  "bridge_model" => "example_bridge_model", # String
  "embeddings" => [], # Array
  "source_model" => "example_source_model", # String
  "target_model" => "example_target_model", # String
  "texts" => [], # Array
})
```

### Common Methods

#### `data_get -> Hash`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get -> Hash`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make -> Entity`

Create a new `ConvertEntity` instance with the same client and
options.

#### `get_name -> String`

Return the entity name.


---

## EmbedEntity

```ruby
embed = client.Embed
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `Array` | Yes | One vector per input text, in input order. |
| `model` | `String` | Yes | Model that produced the vectors. |
| `texts` | `Array` | Yes | Texts to embed. |

### Operations

#### `create(reqdata, ctrl = nil) -> result`

Create a new entity with the given data. Raises on error.

```ruby
result = client.Embed.create({
  "embeddings" => [], # Array
  "model" => "example_model", # String
  "texts" => [], # Array
})
```

### Common Methods

#### `data_get -> Hash`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get -> Hash`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make -> Entity`

Create a new `EmbedEntity` instance with the same client and
options.

#### `get_name -> String`

Return the entity name.


---

## EphemeralKeyEntity

```ruby
ephemeral_key = client.EphemeralKey
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `Integer` | Yes | Calls permitted per day. |
| `dailyUsed` | `Integer` | Yes | Calls already used today. |
| `key` | `String` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata, ctrl = nil) -> result`

Create a new entity with the given data. Raises on error.

```ruby
result = client.EphemeralKey.create({
  "dailyLimit" => 1, # Integer
  "dailyUsed" => 1, # Integer
  "key" => "example_key", # String
  "resetsAt" => "example_resetsAt", # String
})
```

### Common Methods

#### `data_get -> Hash`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get -> Hash`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make -> Entity`

Create a new `EphemeralKeyEntity` instance with the same client and
options.

#### `get_name -> String`

Return the entity name.


---

## ModelEntity

```ruby
model = client.Model
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Hash` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | No | Hardware backend, e.g. |
| `modelCard` | `Hash` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Yes | Model identifier used in requests. |
| `sequenceLen` | `Integer` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `Integer` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String` | No | Convert models only: the source model space. |
| `targetDim` | `Integer` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String` | Yes | The model space produced. |

### Operations

#### `list(reqmatch = nil, ctrl = nil) -> Array`

List entities matching the given criteria (call with no argument to list all). Returns an array. Raises on error.

```ruby
results = client.Model.list
```

### Common Methods

#### `data_get -> Hash`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get -> Hash`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make -> Entity`

Create a new `ModelEntity` instance with the same client and
options.

#### `get_name -> String`

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

```ruby
client = UnivecSDK.new({
  "feature" => {
    "audit" => { "active" => true },
    "cache" => { "active" => true },
    "clienttrack" => { "active" => true },
    "cost" => { "active" => true },
    "debug" => { "active" => true },
    "idempotency" => { "active" => true },
    "log" => { "active" => true },
    "metrics" => { "active" => true },
    "netsim" => { "active" => true },
    "paging" => { "active" => true },
    "proxy" => { "active" => true },
    "ratelimit" => { "active" => true },
    "rbac" => { "active" => true },
    "retry" => { "active" => true },
    "streaming" => { "active" => true },
    "telemetry" => { "active" => true },
    "test" => { "active" => true },
    "timeout" => { "active" => true },
  },
})
```

