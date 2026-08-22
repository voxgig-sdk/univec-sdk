# Univec Rust SDK



The Rust SDK for the Univec API — an entity-oriented client following idiomatic Rust conventions.

The SDK exposes the API as capitalised, semantic **Entities** — for example `client.convert(Value::Noval)` — each
carrying a small, uniform set of operations (`list`, `create`) instead of raw URL
paths and query strings. You work with named resources and verbs, which
keeps the cognitive load low.

> Other languages, the CLI, and MCP server live alongside this one — see
> the [top-level README](../README.md).


## Install
This crate is not yet published to crates.io. Depend on it from the GitHub
release tag (`rust/vX.Y.Z`, see [Releases](https://github.com/voxgig-sdk/univec-sdk/releases)) or
from a source checkout by adding it to your `Cargo.toml`:

```toml
[dependencies]
# From a source checkout:
voxgig-univec-sdk = { path = "../rust" }

# Or from the git release tag:
# voxgig-univec-sdk = { git = "<repo-url>", tag = "rust/vX.Y.Z" }
```


## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.

### 1. Create a client

```rust
use univec_sdk::{getp, jo, UnivecSDK, Value};

let client = UnivecSDK::new(jo(vec![
    ("apikey", Value::str(std::env::var("UNIVEC_APIKEY").unwrap_or_default())),
]));
```

### 4. Create, update, and remove

```rust
// Create — returns the bare created record
let created = client.convert(Value::Noval).create(jo(vec![("bridge_model", Value::str("example_bridge_model")), ("embeddings", Value::empty_list()), ("source_model", Value::str("example_source_model")), ("target_model", Value::str("example_target_model")), ("texts", Value::empty_list())]), Value::Noval).unwrap();

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

For endpoints not covered by entity methods:

```rust
let result = client.direct(jo(vec![
    ("path", Value::str("/api/resource/{id}")),
    ("method", Value::str("GET")),
    ("params", jo(vec![("id", Value::str("example"))])),
])).unwrap();

if getp(&result, "ok") == Value::Bool(true) {
    println!("{:?}", getp(&result, "status"));  // 200
    println!("{:?}", getp(&result, "data"));    // response body
} else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present.
    println!("{:?} {:?}", getp(&result, "status"), getp(&result, "err"));
}
```

### Prepare a request without sending it

```rust
// prepare() returns the fetch definition on Ok and Err on failure.
let fetchdef = client.prepare(jo(vec![
    ("path", Value::str("/api/resource/{id}")),
    ("method", Value::str("DELETE")),
    ("params", jo(vec![("id", Value::str("example"))])),
])).unwrap();

println!("{:?}", getp(&fetchdef, "url"));
println!("{:?}", getp(&fetchdef, "method"));
println!("{:?}", getp(&fetchdef, "headers"));
```

### Use test mode

Create a mock client for unit testing — no server required:

```rust
let client = test_sdk(Value::Noval, Value::Noval);

// Entity ops return the bare record on Ok and Err on failure.
let model = client.model(Value::Noval).list(Value::Noval, Value::Noval).unwrap();
// model contains the mock response record
```

### Point at a different server

Override the base URL to reach a local or staging server:

```rust
let client = UnivecSDK::new(jo(vec![
    ("base", Value::str("http://localhost:8080")),
]));
```

### Run live tests

Create a `.env.local` file at the crate root:

```
UNIVEC_TEST_LIVE=TRUE
UNIVEC_APIKEY=<your-key>
```

Then run:

```bash
cd rust && cargo test
```


## Reference

### UnivecSDK

```rust
use univec_sdk::{UnivecSDK, Value};

let client = UnivecSDK::new(options);
```

Creates a new SDK client. `options` is a `Value` map (`Value::Noval` for
none) carrying any of the following keys:

| Option | Value type | Description |
| --- | --- | --- |
| `apikey` | `string` | API key for authentication. |
| `base` | `string` | Base URL of the API server. |
| `prefix` | `string` | URL path prefix prepended to all requests. |
| `suffix` | `string` | URL path suffix appended to all requests. |
| `feature` | `map` | Feature activation flags. |
| `system` | `map` | System overrides (e.g. a custom fetcher). |

### test_sdk

```rust
use univec_sdk::{test_sdk, Value};

let client = test_sdk(testopts, sdkopts);
```

Creates a test-mode client with mock transport. Both arguments may be
`Value::Noval`.

### UnivecSDK methods

| Method | Signature | Description |
| --- | --- | --- |
| `options_map` | `() -> Value` | Deep copy of the current SDK options. |
| `get_utility` | `() -> Rc<Utility>` | Copy of the SDK utility object. |
| `prepare` | `(fetchargs: Value) -> Result<Value, UnivecError>` | Build an HTTP request definition without sending. |
| `direct` | `(fetchargs: Value) -> Result<Value, UnivecError>` | Build and send an HTTP request. `Ok` is a result map (branch on `ok`). |
| `convert` | `(entopts: Value) -> Rc<ConvertEntity>` | Create a Convert entity instance. |
| `embed` | `(entopts: Value) -> Rc<EmbedEntity>` | Create an Embed entity instance. |
| `ephemeral_key` | `(entopts: Value) -> Rc<EphemeralKeyEntity>` | Create an EphemeralKey entity instance. |
| `model` | `(entopts: Value) -> Rc<ModelEntity>` | Create a Model entity instance. |

### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
| `list` | `(reqmatch: Value, ctrl: Value) -> Result<Value, UnivecError>` | List entities matching the criteria (Ok is a `Value::List`). |
| `create` | `(reqdata: Value, ctrl: Value) -> Result<Value, UnivecError>` | Create a new entity. |
| `data` | `(args: Option<&Value>) -> Value` | Get entity data (pass `Some(&map)` to set). |
| `matchv` | `(args: Option<&Value>) -> Value` | Get entity match criteria (pass `Some(&map)` to set). |
| `make` | `() -> Rc<dyn Entity>` | Create a new instance with the same options. |
| `get_name` | `() -> String` | Return the entity name. |

### Result shape

Entity operations return `Result<Value, UnivecError>` — the
bare result data on `Ok` (a `Value::Map` for single-entity ops, a
`Value::List` for `list`) and the branded error on `Err`.

The `direct()` escape hatch resolves to `Ok` even on a non-2xx response —
it returns a result `Value::Map` you branch on via `getp(&result, "ok")`:

| Key | Type | Description |
| --- | --- | --- |
| `ok` | `bool` | `true` if the HTTP status is 2xx. |
| `status` | `number` | HTTP status code. |
| `headers` | `map` | Response headers. |
| `data` | `any` | Parsed JSON response body. |

On error, `ok` is `false` and `err` carries the error value.

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

Create an instance: `let convert = client.convert(Value::Noval);`

#### Operations

| Method | Description |
| --- | --- |
| `create(reqdata, ctrl)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `bridge_model` | `String` | Embed model used to vectorise the text before translation. |
| `embeddings` | `Vec<Value>` | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Model space to translate into. |
| `texts` | `Vec<Value>` | Texts to embed and translate. |

#### Example: Create

```rust
let convert = client.convert(Value::Noval).create(jo(vec![
    ("bridge_model", Value::str("example_bridge_model")),  // String
    ("embeddings", Value::empty_list()),  // Vec<Value>
    ("source_model", Value::str("example_source_model")),  // String
    ("target_model", Value::str("example_target_model")),  // String
    ("texts", Value::empty_list()),  // Vec<Value>
]), Value::Noval).unwrap();
```


### Embed

Create an instance: `let embed = client.embed(Value::Noval);`

#### Operations

| Method | Description |
| --- | --- |
| `create(reqdata, ctrl)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `Vec<Value>` | One vector per input text, in input order. |
| `model` | `String` | Model that produced the vectors. |
| `texts` | `Vec<Value>` | Texts to embed. |

#### Example: Create

```rust
let embed = client.embed(Value::Noval).create(jo(vec![
    ("embeddings", Value::empty_list()),  // Vec<Value>
    ("model", Value::str("example_model")),  // String
    ("texts", Value::empty_list()),  // Vec<Value>
]), Value::Noval).unwrap();
```


### EphemeralKey

Create an instance: `let ephemeral_key = client.ephemeral_key(Value::Noval);`

#### Operations

| Method | Description |
| --- | --- |
| `create(reqdata, ctrl)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `dailyLimit` | `i64` | Calls permitted per day. |
| `dailyUsed` | `i64` | Calls already used today. |
| `key` | `String` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | When the daily allowance resets. |

#### Example: Create

```rust
let ephemeral_key = client.ephemeral_key(Value::Noval).create(jo(vec![
    ("dailyLimit", Value::Num(1.0)),  // i64
    ("dailyUsed", Value::Num(1.0)),  // i64
    ("key", Value::str("example_key")),  // String
    ("resetsAt", Value::str("example_resetsAt")),  // String
]), Value::Noval).unwrap();
```


### Model

Create an instance: `let model = client.model(Value::Noval);`

#### Operations

| Method | Description |
| --- | --- |
| `list(reqmatch, ctrl)` | List entities, optionally matching the given criteria. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `eval` | `std::collections::HashMap<String, Value>` | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | Hardware backend, e.g. |
| `modelCard` | `std::collections::HashMap<String, Value>` | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Model identifier used in requests. |
| `sequenceLen` | `i64` | Embed models only: maximum input sequence length. |
| `sourceDim` | `i64` | Convert models only: source vector dimension. |
| `sourceModel` | `String` | Convert models only: the source model space. |
| `targetDim` | `i64` | Dimension of the produced vectors. |
| `targetModel` | `String` | The model space produced. |

#### Example: List

```rust
let models = client.model(Value::Noval).list(Value::Noval, Value::Noval).unwrap();
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

Features are the extension mechanism. A feature is an object with a
`hooks` map. Each hook key is a pipeline stage name, and the value is
a function that receives the context.

The SDK ships with built-in features:

- **TestFeature**: In-memory mock transport for testing without a live server

Features are initialized in order. Hooks fire in the order features
were added, so later features can override earlier ones.

### Data as `Value`

The Rust SDK uses a single dynamic `Value` type throughout rather than a
typed struct per entity. `Value` is the vendored voxgig struct port (a
JSON-shaped enum: `Str`, `Num`, `Bool`, `List`, `Map`, `Null`,
`Noval`). This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

Build request maps with the `jo` / `ja` helpers and read fields back with
`getp`; use `to_map` to safely coerce a value to a map.

### Crate structure

```
rust/
├── lib.rs                       -- Crate root (module decls + re-exports)
├── core/                        -- Pipeline types, config, client (sdk.rs)
├── entity/                      -- Per-entity clients (one module each)
├── feature/                     -- Built-in features (base, test, log)
└── utility/                     -- Utilities + the vendored voxgig struct port
```

The public API is re-exported from the crate root, so `use univec_sdk::{...}`
reaches the SDK client, `Value`, and the `jo` / `ja` / `getp` helpers
directly. Import entity or utility modules only when needed.

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
