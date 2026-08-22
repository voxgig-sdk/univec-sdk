# Univec Golang SDK



The Golang SDK for the Univec API — an entity-oriented client using standard Go conventions. No generics required; data flows as `map[string]any`.

It exposes the API as capitalised, semantic **Entities** — e.g. `client.Convert(nil)` — each with the same small set of operations (`List`, `Create`) instead of raw URL paths and query strings. You call meaning, not endpoints, which keeps the cognitive load low.

> Also generated from this model: `go-cli`, `go-mcp`, `js`, `lua`, `php`, `py`, `ts` — see
> the [top-level README](../README.md).


## Install
```bash
go get github.com/voxgig-sdk/univec-sdk/go@latest
```

The Go module proxy resolves the version from the `go/vX.Y.Z` GitHub
release tag — see [Releases](https://github.com/voxgig-sdk/univec-sdk/releases) for the available versions.

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
Each operation returns `(value, error)` — the value is the data itself
(there is no `{ok, data}` wrapper), so check `err` and use the value
directly.

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
    created, err := client.Convert(nil).Create(map[string]any{"bridge_model": "example_bridge_model", "embeddings": []any{}, "source_model": "example_source_model", "target_model": "example_target_model", "texts": []any{}}, nil)
    if err != nil {
        panic(err)
    }
    fmt.Println(created)
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

model, err := client.Model(nil).List(
    nil, nil,
)
if err != nil {
    panic(err)
}
fmt.Println(model) // the returned mock data
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
| `List` | `(reqmatch, ctrl map[string]any) (any, error)` | List entities matching the criteria. |
| `Create` | `(reqdata, ctrl map[string]any) (any, error)` | Create a new entity. |
| `Data` | `(args ...any) any` | Get or set entity data. |
| `Match` | `(args ...any) any` | Get or set entity match criteria. |
| `Make` | `() Entity` | Create a new instance with the same options. |
| `GetName` | `() string` | Return the entity name. |

### Result shape

Entity operations return `(value, error)`. The `value` is the
operation's data **directly** — there is no wrapper:

| Operation | `value` |
| --- | --- |
| `Create` | the entity record (`map[string]any`) |
| `List` | a `[]any` of entity records |

Check `err` first, then use the value directly (or the typed
`...Typed` variants, which return the entity's model struct and a typed
slice):

    convert, err := client.Convert(nil).Create(map[string]any{/* fields */}, nil)
    if err != nil { /* handle */ }
    // convert is the returned record

Only `Direct()` returns a response envelope — a `map[string]any` with
`"ok"`, `"status"`, `"headers"`, and `"data"` keys.

### Entities

#### Convert

| Field | Description |
| --- | --- |
| `"bridge_model"` | Embed model used to vectorise the text before translation. |
| `"embeddings"` | Translated vectors, in the target model's dimension. |
| `"source_model"` | Model space the supplied vectors are currently in. |
| `"target_model"` | Model space to translate into. |
| `"texts"` | Texts to embed and translate. |

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
| `bridge_model` | `string` | Embed model used to vectorise the text before translation. |
| `embeddings` | `[]any` | Translated vectors, in the target model's dimension. |
| `source_model` | `string` | Model space the supplied vectors are currently in. |
| `target_model` | `string` | Model space to translate into. |
| `texts` | `[]any` | Texts to embed and translate. |

#### Example: Create

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
fmt.Println(result)
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
fmt.Println(result)
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
fmt.Println(models) // the array of records
```


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

- **TestFeature**: In-memory mock transport for testing without a live server

Features are initialized in order. Hooks fire in the order features
were added, so later features can override earlier ones.

### Data as maps

The Go SDK uses `map[string]any` throughout rather than typed structs.
This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

Use `core.ToMapAny()` to safely cast results and nested data.

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
