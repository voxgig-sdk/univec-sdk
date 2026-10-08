# Univec Golang SDK



The Golang SDK for the Univec API — an entity-oriented client using standard Go conventions. No generics required; data flows as `map[string]any`.

It exposes the API as capitalised, semantic **Entities** — e.g. `client.Convert(nil)` — each with the same small set of operations (`List`, `Create`) instead of raw URL paths and query strings. You call meaning, not endpoints, which keeps the cognitive load low.

> Also generated from this model: `c`, `clojure`, `cpp`, `csharp`, `dart`, `elixir`, `go-cli`, `go-mcp`, `haskell`, `java`, `js`, `kotlin`, `lean`, `lua`, `ocaml`, `perl`, `php`, `py`, `py-data`, `rb`, `rust`, `scala`, `swift`, `ts`, `zig` — see
> the [top-level README](../README.md).


## Install
```bash
go get github.com/voxgig-sdk/univec-sdk/go@latest
```

The Go module proxy resolves the version from the `go/vX.Y.Z` GitHub
release tag — see [Tags](https://github.com/voxgig-sdk/univec-sdk/tags) for the available versions.

To vendor from a local checkout instead, clone this repo alongside your
project and add a `replace` directive pointing at the checked-out
`go/` directory:

```bash
go mod edit -replace github.com/voxgig-sdk/univec-sdk/go=../univec-sdk/go
```


## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.

### Quickstart

A complete program: create a client, then call the entity operations.
Each operation returns `(value, error)` — the value is the entity, and for
`List` a `[]any` of entities, one per record (there is no `{ok, data}`
wrapper), so check `err` and read a record through the entity's
`Data()`.

```go
package main

import (
    "fmt"
    "os"
    sdk "github.com/voxgig-sdk/univec-sdk/go"
)

func main() {
    client := sdk.NewUnivecSDK(map[string]any{
        "apikey": os.Getenv("UNIVEC_APIKEY"),
    })

    // Create a convert.
    created, err := client.Convert(nil).Create(map[string]any{"embeddings": []any{}, "source_model": "example_source_model", "target_model": "example_target_model"}, nil)
    if err != nil {
        panic(err)
    }
    fmt.Println(created.(sdk.Entity).Data())
}
```


## Error handling

Every entity operation returns `(value, error)`. Check `err` before
using the value — there is no exception to catch:

```go
models, err := client.Model(nil).List(nil, nil)
if err != nil {
    // handle err
    return
}
_ = models
```

`Direct` follows the same `(value, error)` convention:

```go
result, err := client.Direct(map[string]any{
    "path":   "/api/resource/{id}",
    "method": "GET",
    "params": map[string]any{"id": "example_id"},
})
if err != nil {
    // handle err
}
_ = result
```


## How-to guides

### Make a direct HTTP request

For endpoints not covered by entity methods:

```go
result, err := client.Direct(map[string]any{
    "path":   "/api/resource/{id}",
    "method": "GET",
    "params": map[string]any{"id": "example"},
})
if err != nil {
    panic(err)
}

if result["ok"] == true {
    fmt.Println(result["status"]) // 200
    fmt.Println(result["data"])   // response body
}
```

### Prepare a request without sending it

```go
fetchdef, err := client.Prepare(map[string]any{
    "path":   "/api/resource/{id}",
    "method": "DELETE",
    "params": map[string]any{"id": "example"},
})
if err != nil {
    panic(err)
}

fmt.Println(fetchdef["url"])
fmt.Println(fetchdef["method"])
fmt.Println(fetchdef["headers"])
```

### Use test mode

Create a mock client for unit testing — no server required:

```go
client := sdk.Test()

models, err := client.Model(nil).List(
    nil, nil,
)
if err != nil {
    panic(err)
}
// A []any of entities, one per mock record.
for _, item := range models.([]any) {
    fmt.Println(item.(sdk.Entity).Data())
}
```

### Use a custom fetch function

Replace the HTTP transport with your own function:

```go
mockFetch := func(url string, init map[string]any) (map[string]any, error) {
    return map[string]any{
        "status":     200,
        "statusText": "OK",
        "headers":    map[string]any{},
        "json": (func() any)(func() any {
            return map[string]any{"id": "mock01"}
        }),
    }, nil
}

client := sdk.NewUnivecSDK(map[string]any{
    "base": "http://localhost:8080",
    "system": map[string]any{
        "fetch": (func(string, map[string]any) (map[string]any, error))(mockFetch),
    },
})
```

### Run live tests

Create a `.env.local` file at the project root:

```
UNIVEC_TEST_LIVE=TRUE
UNIVEC_APIKEY=<your-key>
```

Then run:

```bash
cd go && go test ./test/...
```


## Reference

### NewUnivecSDK

```go
func NewUnivecSDK(options map[string]any) *UnivecSDK
```

Creates a new SDK client.

| Option | Type | Description |
| --- | --- | --- |
| `"apikey"` | `string` | API key for authentication. |
| `"base"` | `string` | Base URL of the API server. |
| `"prefix"` | `string` | URL path prefix prepended to all requests. |
| `"suffix"` | `string` | URL path suffix appended to all requests. |
| `"feature"` | `map[string]any` | Feature activation flags. |
| `"extend"` | `[]any` | Additional Feature instances to load. |
| `"system"` | `map[string]any` | System overrides (e.g. custom `"fetch"` function). |

### TestSDK

```go
func TestSDK(testopts map[string]any, sdkopts map[string]any) *UnivecSDK
```

Creates a test-mode client with mock transport. Both arguments may be `nil`.

### UnivecSDK methods

| Method | Signature | Description |
| --- | --- | --- |
| `OptionsMap` | `() map[string]any` | Deep copy of current SDK options. |
| `GetUtility` | `() *Utility` | Copy of the SDK utility object. |
| `Prepare` | `(fetchargs map[string]any) (map[string]any, error)` | Build an HTTP request definition without sending. |
| `Direct` | `(fetchargs map[string]any) (map[string]any, error)` | Build and send an HTTP request. |
| `Convert` | `(data map[string]any) UnivecEntity` | Create a Convert entity instance. |
| `Embed` | `(data map[string]any) UnivecEntity` | Create an Embed entity instance. |
| `EphemeralKey` | `(data map[string]any) UnivecEntity` | Create an EphemeralKey entity instance. |
| `Model` | `(data map[string]any) UnivecEntity` | Create a Model entity instance. |

### Entity interface (UnivecEntity)

All entities implement the `UnivecEntity` interface.

| Method | Signature | Description |
| --- | --- | --- |
| `List` | `(reqmatch, ctrl map[string]any) (any, error)` | List entities matching the criteria, one per record. |
| `Create` | `(reqdata, ctrl map[string]any) (any, error)` | Create a new entity, and return it. |
| `Data` | `(args ...any) any` | Get or set entity data. |
| `Match` | `(args ...any) any` | Get or set entity match criteria. |
| `Make` | `() Entity` | Create a new instance with the same options. |
| `GetName` | `() string` | Return the entity name. |

### Result shape

Entity operations return `(value, error)`. The `value` is the entity
itself — there is no wrapper:

| Operation | `value` |
| --- | --- |
| `Create` | the entity, whose `Data()` reads its record (`map[string]any`) |
| `List` | a `[]any` of entities, one per record |

Check `err` first, then use the value directly (or the typed
`...Typed` variants, which return the entity's model struct and a typed
slice):

    convert, err := client.Convert(nil).Create(map[string]any{/* fields */}, nil)
    if err != nil { /* handle */ }
    // convert is the entity; convert.(sdk.Entity).Data() reads its record

Only `Direct()` returns a response envelope — a `map[string]any` with
`"ok"`, `"status"`, `"headers"`, and `"data"` keys.

### Entities

#### Convert

| Field | Description |
| --- | --- |
| `"embeddings"` | Translated vectors, in the target model's dimension. |
| `"source_model"` | Model space the supplied vectors are currently in. |
| `"target_model"` | Model space to translate into. |

Operations: Create.

API path: `/v1/convert`

#### Embed

| Field | Description |
| --- | --- |
| `"embeddings"` | One vector per input text, in input order. |
| `"model"` | Model that produced the vectors. |
| `"texts"` | Texts to embed. |

Operations: Create.

API path: `/v1/embed`

#### EphemeralKey

| Field | Description |
| --- | --- |
| `"dailyLimit"` | Calls permitted per day. |
| `"dailyUsed"` | Calls already used today. |
| `"key"` | The ephemeral API key, prefixed `eph_`. |
| `"resetsAt"` | When the daily allowance resets. |

Operations: Create.

API path: `/v1/ephemeral/key`

#### Model

| Field | Description |
| --- | --- |
| `"eval"` | Retrieval-fidelity metrics for a convert model. |
| `"executionProvider"` | Hardware backend, e.g. |
| `"modelCard"` | Convert models only: training provenance and architecture detail. |
| `"modelType"` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `"name"` | Model identifier used in requests. |
| `"sequenceLen"` | Embed models only: maximum input sequence length. |
| `"sourceDim"` | Convert models only: source vector dimension. |
| `"sourceModel"` | Convert models only: the source model space. |
| `"targetDim"` | Dimension of the produced vectors. |
| `"targetModel"` | The model space produced. |

Operations: List.

API path: `/v1/models`



## Entities


### Convert

Create an instance: `convert := client.Convert(nil)`

#### Operations

| Method | Description |
| --- | --- |
| `Create(data, ctrl)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `[]any` | Translated vectors, in the target model's dimension. |
| `source_model` | `string` | Model space the supplied vectors are currently in. |
| `target_model` | `string` | Model space to translate into. |

#### Example: Create

```go
result, err := client.Convert(nil).Create(map[string]any{
    "embeddings": []any{},
    "source_model": "example_source_model",
    "target_model": "example_target_model",
}, nil)
if err != nil {
    panic(err)
}
fmt.Println(result.(sdk.Entity).Data()) // the created entity's record
```


### Embed

Create an instance: `embed := client.Embed(nil)`

#### Operations

| Method | Description |
| --- | --- |
| `Create(data, ctrl)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `[]any` | One vector per input text, in input order. |
| `model` | `string` | Model that produced the vectors. |
| `texts` | `[]any` | Texts to embed. |

#### Example: Create

```go
result, err := client.Embed(nil).Create(map[string]any{
    "embeddings": []any{},
    "model": "example_model",
    "texts": []any{},
}, nil)
if err != nil {
    panic(err)
}
fmt.Println(result.(sdk.Entity).Data()) // the created entity's record
```


### EphemeralKey

Create an instance: `ephemeralKey := client.EphemeralKey(nil)`

#### Operations

| Method | Description |
| --- | --- |
| `Create(data, ctrl)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `dailyLimit` | `int` | Calls permitted per day. |
| `dailyUsed` | `int` | Calls already used today. |
| `key` | `string` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `string` | When the daily allowance resets. |

#### Example: Create

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
fmt.Println(result.(sdk.Entity).Data()) // the created entity's record
```


### Model

Create an instance: `model := client.Model(nil)`

#### Operations

| Method | Description |
| --- | --- |
| `List(match, ctrl)` | List entities matching the criteria. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `eval` | `map[string]any` | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `string` | Hardware backend, e.g. |
| `modelCard` | `map[string]any` | Convert models only: training provenance and architecture detail. |
| `modelType` | `string` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `string` | Model identifier used in requests. |
| `sequenceLen` | `int` | Embed models only: maximum input sequence length. |
| `sourceDim` | `int` | Convert models only: source vector dimension. |
| `sourceModel` | `string` | Convert models only: the source model space. |
| `targetDim` | `int` | Dimension of the produced vectors. |
| `targetModel` | `string` | The model space produced. |

#### Example: List

```go
models, err := client.Model(nil).List(nil, nil)
if err != nil {
    panic(err)
}
// A []any of entities, one per record.
for _, item := range models.([]any) {
    fmt.Println(item.(sdk.Entity).Data())
}
```

## Features

This SDK ships 19 optional features. Each is **inactive until you
switch it on**, so an SDK you have not configured behaves exactly as if none of
them existed — no retries, no cache, no logging, no measurable overhead.

Activate a feature by name in the client options, alongside the options shown
above:

| Feature | What it does |
|---|---|
| [`audit`](#audit) | Audit trail |
| [`cache`](#cache) | Response cache |
| [`clienttrack`](#clienttrack) | Client tracking |
| [`cost`](#cost) | Cost tracking |
| [`debug`](#debug) | Debug capture |
| [`idempotency`](#idempotency) | Idempotency |
| [`log`](#log) | Logging |
| [`metrics`](#metrics) | Metrics |
| [`netsim`](#netsim) | Network simulation |
| [`paging`](#paging) | Paging |
| [`proxy`](#proxy) | Proxy |
| [`ratelimit`](#ratelimit) | Rate limiting |
| [`rbac`](#rbac) | Access control |
| [`retry`](#retry) | Retry |
| [`secrets`](#secrets) | Secrets |
| [`streaming`](#streaming) | Streaming |
| [`telemetry`](#telemetry) | Telemetry |
| [`test`](#test) | Test transport |
| [`timeout`](#timeout) | Timeout |

> **Order matters for `cache`, `cost`, `netsim`, `proxy`, `ratelimit`, `retry`, `secrets`, `timeout`.** These wrap the
> transport, so each one wraps whatever is already installed: the order you
> activate them in IS the nesting order. Activating them as an ordered list
> rather than a map is what fixes that order.

### audit

Audit trail.

| Option | Default |
|---|---|
| `active` | `false` |
| `actor` | `'anonymous'` |
| `max` | `1000` |

Set `feature.audit.active` to enable it, then override any of the options above.

### cache

Response cache.

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

Client tracking.

| Option | Default |
|---|---|
| `active` | `false` |
| `clientVersion` | `'0.0.1'` |

Set `feature.clienttrack.active` to enable it, then override any of the options above.

### cost

Cost tracking.

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

Debug capture.

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `100` |
| `redact` | `['authorization', 'cookie', 'set-cookie', 'api-key', 'apikey', 'x-api-key', 'idempotency-key']` |

Set `feature.debug.active` to enable it, then override any of the options above.

### idempotency

Idempotency.

| Option | Default |
|---|---|
| `active` | `false` |
| `header` | `'Idempotency-Key'` |
| `methods` | `['POST', 'PUT', 'PATCH', 'DELETE']` |
| `ops` | `['create', 'update', 'remove']` |

Set `feature.idempotency.active` to enable it, then override any of the options above.

### log

Logging.

| Option | Default |
|---|---|
| `active` | `true` |

Set `feature.log.active` to enable it, then override any of the options above.

### metrics

Metrics.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.metrics.active` to enable it, then override any of the options above.

### netsim

Network simulation.

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

Paging.

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

Proxy.

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

Rate limiting.

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

Access control.

| Option | Default |
|---|---|
| `active` | `false` |
| `deny` | `false` |
| `permissions` | `[]` |
| `rules` | `{}` |

Set `feature.rbac.active` to enable it, then override any of the options above.

### retry

Retry.

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

### secrets

Secrets.

| Option | Default |
|---|---|
| `active` | `false` |
| `cache` | `true` |
| `exchange` | `{active: false, method: 'POST', path: 'auth/token', refresh: '', request: 'refresh_token', response: 'access_token', retries: 1, statuses: [401]}` |
| `name` | `'univec'` |
| `providers` | `[{kind: 'boru', namespace: 'sdk'}]` |

Set `feature.secrets.active` to enable it, then override any of the options above.

`secrets` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### streaming

Streaming.

| Option | Default |
|---|---|
| `active` | `false` |
| `chunkDelay` | `0` |
| `chunkSize` | `0` |

Set `feature.streaming.active` to enable it, then override any of the options above.

### telemetry

Telemetry.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.telemetry.active` to enable it, then override any of the options above.

### test

Test transport.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.test.active` to enable it, then override any of the options above.

### timeout

Timeout.

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

Features are the extension mechanism. A feature implements the
`Feature` interface and provides hooks — functions keyed by pipeline
stage names.

The SDK ships with built-in features:

- **AuditFeature**: Audit trail
- **CacheFeature**: Response cache
- **ClienttrackFeature**: Client tracking
- **CostFeature**: Cost tracking
- **DebugFeature**: Debug capture
- **IdempotencyFeature**: Idempotency
- **LogFeature**: Logging
- **MetricsFeature**: Metrics
- **NetsimFeature**: Network simulation
- **PagingFeature**: Paging
- **ProxyFeature**: Proxy
- **RatelimitFeature**: Rate limiting
- **RbacFeature**: Access control
- **RetryFeature**: Retry
- **SecretsFeature**: Secrets
- **StreamingFeature**: Streaming
- **TelemetryFeature**: Telemetry
- **TestFeature**: Test transport
- **TimeoutFeature**: Timeout

Features are initialized in order. Hooks fire in the order features
were added, so later features can override earlier ones.

### Data as maps

The Go SDK uses `map[string]any` throughout rather than typed structs.
This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

An operation returns the entity, and its `Data()` returns the record. Use
`core.ToMapAny()` to safely cast that record, or data nested in it, to
`map[string]any`: it returns `nil` for anything else, an entity included.

### Package structure

```
github.com/voxgig-sdk/univec-sdk/go/
├── univec.go        # Root package — type aliases and constructors
├── core/               # SDK core — client, types, pipeline
├── entity/             # Entity implementations
├── feature/            # Built-in features (Base, Test, Log)
├── utility/            # Utility functions and struct library
└── test/               # Test suites
```

The root package (`github.com/voxgig-sdk/univec-sdk/go`) re-exports everything needed
for normal use. Import sub-packages only when you need specific types
like `core.ToMapAny`.

### Entity state

Entity instances are stateful. After a successful `List`, the entity
stores the returned data and match criteria internally.

```go
model := client.Model(nil)
model.List(nil, nil)

// model.Data() now returns the model data from the last list
// model.Match() returns the last match criteria
```

Call `Make()` to create a fresh instance with the same configuration
but no stored state.

### Direct vs entity access

The entity interface handles URL construction, parameter placement,
and response parsing automatically. Use it for standard CRUD operations.

`Direct()` gives full control over the HTTP request. Use it for
non-standard endpoints, bulk operations, or any path not modelled as
an entity. `Prepare()` builds the request without sending it — useful
for debugging or custom transport.


## Full Reference

See [REFERENCE.md](REFERENCE.md) for complete API reference
documentation including all method signatures, entity field schemas,
and detailed usage examples.
