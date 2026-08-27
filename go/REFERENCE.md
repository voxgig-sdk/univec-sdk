# Univec Golang SDK Reference

Complete API reference for the Univec Golang SDK.


## UnivecSDK

### Constructor

```go
func NewUnivecSDK(options map[string]any) *UnivecSDK
```

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `map[string]any` | SDK configuration options. |
| `options["apikey"]` | `string` | API key for authentication. |
| `options["base"]` | `string` | Base URL for API requests. |
| `options["prefix"]` | `string` | URL prefix appended after base. |
| `options["suffix"]` | `string` | URL suffix appended after path. |
| `options["headers"]` | `map[string]any` | Custom headers for all requests. |
| `options["feature"]` | `map[string]any` | Feature configuration. |
| `options["system"]` | `map[string]any` | System overrides (e.g. custom fetch). |


### Static Methods

#### `Test() *UnivecSDK`

No-arg convenience constructor for the common no-options test case.

```go
client := sdk.Test()
```

#### `TestSDK(testopts, sdkopts map[string]any) *UnivecSDK`

Test client with options. Both arguments may be `nil`.

```go
client := sdk.TestSDK(testopts, sdkopts)
```


### Instance Methods

#### `Convert(data map[string]any) UnivecEntity`

Create a new `Convert` entity instance. Pass `nil` for no initial data.

#### `Embed(data map[string]any) UnivecEntity`

Create a new `Embed` entity instance. Pass `nil` for no initial data.

#### `EphemeralKey(data map[string]any) UnivecEntity`

Create a new `EphemeralKey` entity instance. Pass `nil` for no initial data.

#### `Model(data map[string]any) UnivecEntity`

Create a new `Model` entity instance. Pass `nil` for no initial data.

#### `OptionsMap() map[string]any`

Return a deep copy of the current SDK options.

#### `GetUtility() *Utility`

Return a copy of the SDK utility object.

#### `Direct(fetchargs map[string]any) (map[string]any, error)`

Make a direct HTTP request to any API endpoint.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs["path"]` | `string` | URL path with optional `{param}` placeholders. |
| `fetchargs["method"]` | `string` | HTTP method (default: `"GET"`). |
| `fetchargs["params"]` | `map[string]any` | Path parameter values for `{param}` substitution. |
| `fetchargs["query"]` | `map[string]any` | Query string parameters. |
| `fetchargs["headers"]` | `map[string]any` | Request headers (merged with defaults). |
| `fetchargs["body"]` | `any` | Request body (maps are JSON-serialized). |
| `fetchargs["ctrl"]` | `map[string]any` | Control options (e.g. `map[string]any{"explain": true}`). |

**Returns:** `(map[string]any, error)`

#### `Prepare(fetchargs map[string]any) (map[string]any, error)`

Prepare a fetch definition without sending the request. Accepts the
same parameters as `Direct()`.

**Returns:** `(map[string]any, error)`


---

## ConvertEntity

```go
convert := client.Convert(nil)
fmt.Println(convert.GetName()) // "convert"
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `string` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `[]any` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `string` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `string` | Yes | Model space to translate into. |
| `texts` | `[]any` | Yes | Texts to embed and translate. |

### Operations

#### `Create(reqdata, ctrl map[string]any) (any, error)`

Create a new entity with the given data.

```go
result, err := client.Convert(nil).Create(map[string]any{
    "bridge_model": "example_bridge_model",
    "embeddings": []any{},
    "source_model": "example_source_model",
    "target_model": "example_target_model",
    "texts": []any{},
}, nil)
if err != nil {
    panic(err)
}
fmt.Println(result)
```

### Common Methods

#### `Data(args ...any) any`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `Match(args ...any) any`

Get or set the entity match criteria. Works the same as `Data()`.

#### `Make() Entity`

Create a new `ConvertEntity` instance with the same client and
options.

#### `GetName() string`

Return the entity name.


---

## EmbedEntity

```go
embed := client.Embed(nil)
fmt.Println(embed.GetName()) // "embed"
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `[]any` | Yes | One vector per input text, in input order. |
| `model` | `string` | Yes | Model that produced the vectors. |
| `texts` | `[]any` | Yes | Texts to embed. |

### Operations

#### `Create(reqdata, ctrl map[string]any) (any, error)`

Create a new entity with the given data.

```go
result, err := client.Embed(nil).Create(map[string]any{
    "embeddings": []any{},
    "model": "example_model",
    "texts": []any{},
}, nil)
if err != nil {
    panic(err)
}
fmt.Println(result)
```

### Common Methods

#### `Data(args ...any) any`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `Match(args ...any) any`

Get or set the entity match criteria. Works the same as `Data()`.

#### `Make() Entity`

Create a new `EmbedEntity` instance with the same client and
options.

#### `GetName() string`

Return the entity name.


---

## EphemeralKeyEntity

```go
ephemeralKey := client.EphemeralKey(nil)
fmt.Println(ephemeralKey.GetName()) // "ephemeral_key"
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `int` | Yes | Calls permitted per day. |
| `dailyUsed` | `int` | Yes | Calls already used today. |
| `key` | `string` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `string` | Yes | When the daily allowance resets. |

### Operations

#### `Create(reqdata, ctrl map[string]any) (any, error)`

Create a new entity with the given data.

```go
result, err := client.EphemeralKey(nil).Create(map[string]any{
    "dailyLimit": 1,
    "dailyUsed": 1,
    "key": "example_key",
    "resetsAt": "example_resetsAt",
}, nil)
if err != nil {
    panic(err)
}
fmt.Println(result)
```

### Common Methods

#### `Data(args ...any) any`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `Match(args ...any) any`

Get or set the entity match criteria. Works the same as `Data()`.

#### `Make() Entity`

Create a new `EphemeralKeyEntity` instance with the same client and
options.

#### `GetName() string`

Return the entity name.


---

## ModelEntity

```go
model := client.Model(nil)
fmt.Println(model.GetName()) // "model"
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `map[string]any` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `string` | No | Hardware backend, e.g. |
| `modelCard` | `map[string]any` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `string` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `string` | Yes | Model identifier used in requests. |
| `sequenceLen` | `int` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `int` | No | Convert models only: source vector dimension. |
| `sourceModel` | `string` | No | Convert models only: the source model space. |
| `targetDim` | `int` | Yes | Dimension of the produced vectors. |
| `targetModel` | `string` | Yes | The model space produced. |

### Operations

#### `List(reqmatch, ctrl map[string]any) (any, error)`

List entities matching the given criteria. Returns an array.

```go
results, err := client.Model(nil).List(nil, nil)
if err != nil {
    panic(err)
}
fmt.Println(results)
```

### Common Methods

#### `Data(args ...any) any`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `Match(args ...any) any`

Get or set the entity match criteria. Works the same as `Data()`.

#### `Make() Entity`

Create a new `ModelEntity` instance with the same client and
options.

#### `GetName() string`

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

```go
client := sdk.NewUnivecSDK(map[string]any{
    "feature": map[string]any{
        "audit": map[string]any{"active": true},
        "cache": map[string]any{"active": true},
        "clienttrack": map[string]any{"active": true},
        "cost": map[string]any{"active": true},
        "debug": map[string]any{"active": true},
        "idempotency": map[string]any{"active": true},
        "log": map[string]any{"active": true},
        "metrics": map[string]any{"active": true},
        "netsim": map[string]any{"active": true},
        "paging": map[string]any{"active": true},
        "proxy": map[string]any{"active": true},
        "ratelimit": map[string]any{"active": true},
        "rbac": map[string]any{"active": true},
        "retry": map[string]any{"active": true},
        "streaming": map[string]any{"active": true},
        "telemetry": map[string]any{"active": true},
        "test": map[string]any{"active": true},
        "timeout": map[string]any{"active": true},
    },
})
```

