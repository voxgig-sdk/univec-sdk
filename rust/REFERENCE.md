# Univec Rust SDK Reference

Complete API reference for the Univec Rust SDK.


## UnivecSDK

### Constructor

```rust
use univec_sdk::{UnivecSDK, Value};

let client = UnivecSDK::new(options);
```

Create a new SDK client instance. `options` is a `Value` map
(`Value::Noval` for none).

**Parameters:**

| Key | Value type | Description |
| --- | --- | --- |
| `apikey` | `string` | API key for authentication. |
| `base` | `string` | Base URL for API requests. |
| `prefix` | `string` | URL prefix appended after base. |
| `suffix` | `string` | URL suffix appended after path. |
| `headers` | `map` | Custom headers for all requests. |
| `feature` | `map` | Feature configuration. |
| `system` | `map` | System overrides. |


### Static Functions

#### `test_sdk(testopts: Value, sdkopts: Value) -> Rc<UnivecSDK>`

Create a test client with mock features active. Both arguments may be
`Value::Noval`.

```rust
use univec_sdk::{test_sdk, Value};

let client = test_sdk(Value::Noval, Value::Noval);
```


### Instance Methods

#### `convert(entopts: Value) -> Rc<ConvertEntity>`

Create a new `ConvertEntity` instance. Pass `Value::Noval` for no
initial options.

#### `embed(entopts: Value) -> Rc<EmbedEntity>`

Create a new `EmbedEntity` instance. Pass `Value::Noval` for no
initial options.

#### `ephemeral_key(entopts: Value) -> Rc<EphemeralKeyEntity>`

Create a new `EphemeralKeyEntity` instance. Pass `Value::Noval` for no
initial options.

#### `model(entopts: Value) -> Rc<ModelEntity>`

Create a new `ModelEntity` instance. Pass `Value::Noval` for no
initial options.

#### `options_map() -> Value`

Return a deep copy of the current SDK options.

#### `get_utility() -> Rc<Utility>`

Return a copy of the SDK utility object.

#### `direct(fetchargs: Value) -> Result<Value, UnivecError>`

Make a direct HTTP request to any API endpoint. `Ok` is a result `Value::Map`
with `ok`, `status`, `headers`, and `data` (or `err` on failure). This
escape hatch resolves to `Ok` even on a non-2xx response — branch on
`getp(&result, "ok")`.

**Parameters (`fetchargs` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| `path` | `string` | URL path with optional `{param}` placeholders. |
| `method` | `string` | HTTP method (default: `"GET"`). |
| `params` | `map` | Path parameter values. |
| `query` | `map` | Query string parameters. |
| `headers` | `map` | Request headers (merged with defaults). |
| `body` | `any` | Request body (maps are JSON-serialized). |

#### `prepare(fetchargs: Value) -> Result<Value, UnivecError>`

Prepare a fetch definition without sending. Returns the fetchdef on `Ok`.


---

## ConvertEntity

```rust
let convert = client.convert(Value::Noval);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `Vec<Value>` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Yes | Model space to translate into. |
| `texts` | `Vec<Value>` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata: Value, ctrl: Value) -> Result<Value, UnivecError>`

Create a new entity with the given data. Returns the created entity data on `Ok` and `Err` on failure.

```rust
let result = client.convert(Value::Noval).create(jo(vec![
    ("bridge_model", Value::str("example_bridge_model")),  // String
    ("embeddings", Value::empty_list()),  // Vec<Value>
    ("source_model", Value::str("example_source_model")),  // String
    ("target_model", Value::str("example_target_model")),  // String
    ("texts", Value::empty_list()),  // Vec<Value>
]), Value::Noval).unwrap();
```

### Common Methods

#### `data(args: Option<&Value>) -> Value`

Get the entity data. Pass `Some(&map)` to set it.

#### `matchv(args: Option<&Value>) -> Value`

Get the entity match criteria. Pass `Some(&map)` to set it.

#### `make() -> Rc<dyn Entity>`

Create a new `ConvertEntity` instance with the same options.

#### `get_name() -> String`

Return the entity name.


---

## EmbedEntity

```rust
let embed = client.embed(Value::Noval);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `Vec<Value>` | Yes | One vector per input text, in input order. |
| `model` | `String` | Yes | Model that produced the vectors. |
| `texts` | `Vec<Value>` | Yes | Texts to embed. |

### Operations

#### `create(reqdata: Value, ctrl: Value) -> Result<Value, UnivecError>`

Create a new entity with the given data. Returns the created entity data on `Ok` and `Err` on failure.

```rust
let result = client.embed(Value::Noval).create(jo(vec![
    ("embeddings", Value::empty_list()),  // Vec<Value>
    ("model", Value::str("example_model")),  // String
    ("texts", Value::empty_list()),  // Vec<Value>
]), Value::Noval).unwrap();
```

### Common Methods

#### `data(args: Option<&Value>) -> Value`

Get the entity data. Pass `Some(&map)` to set it.

#### `matchv(args: Option<&Value>) -> Value`

Get the entity match criteria. Pass `Some(&map)` to set it.

#### `make() -> Rc<dyn Entity>`

Create a new `EmbedEntity` instance with the same options.

#### `get_name() -> String`

Return the entity name.


---

## EphemeralKeyEntity

```rust
let ephemeral_key = client.ephemeral_key(Value::Noval);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `i64` | Yes | Calls permitted per day. |
| `dailyUsed` | `i64` | Yes | Calls already used today. |
| `key` | `String` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata: Value, ctrl: Value) -> Result<Value, UnivecError>`

Create a new entity with the given data. Returns the created entity data on `Ok` and `Err` on failure.

```rust
let result = client.ephemeral_key(Value::Noval).create(jo(vec![
    ("dailyLimit", Value::Num(1.0)),  // i64
    ("dailyUsed", Value::Num(1.0)),  // i64
    ("key", Value::str("example_key")),  // String
    ("resetsAt", Value::str("example_resetsAt")),  // String
]), Value::Noval).unwrap();
```

### Common Methods

#### `data(args: Option<&Value>) -> Value`

Get the entity data. Pass `Some(&map)` to set it.

#### `matchv(args: Option<&Value>) -> Value`

Get the entity match criteria. Pass `Some(&map)` to set it.

#### `make() -> Rc<dyn Entity>`

Create a new `EphemeralKeyEntity` instance with the same options.

#### `get_name() -> String`

Return the entity name.


---

## ModelEntity

```rust
let model = client.model(Value::Noval);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `std::collections::HashMap<String, Value>` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | No | Hardware backend, e.g. |
| `modelCard` | `std::collections::HashMap<String, Value>` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Yes | Model identifier used in requests. |
| `sequenceLen` | `i64` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `i64` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String` | No | Convert models only: the source model space. |
| `targetDim` | `i64` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String` | Yes | The model space produced. |

### Operations

#### `list(reqmatch: Value, ctrl: Value) -> Result<Value, UnivecError>`

List entities matching the given criteria. The match is optional — pass `Value::Noval` to list all records. `Ok` is a `Value::List`.

```rust
let results = client.model(Value::Noval).list(Value::Noval, Value::Noval).unwrap();
if let Value::List(items) = &results {
    for model in items.borrow().iter() {
        println!("{:?}", model);
    }
}
```

### Common Methods

#### `data(args: Option<&Value>) -> Value`

Get the entity data. Pass `Some(&map)` to set it.

#### `matchv(args: Option<&Value>) -> Value`

Get the entity match criteria. Pass `Some(&map)` to set it.

#### `make() -> Rc<dyn Entity>`

Create a new `ModelEntity` instance with the same options.

#### `get_name() -> String`

Return the entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```rust
let client = UnivecSDK::new(jo(vec![
    ("feature", jo(vec![
        ("test", jo(vec![("active", Value::Bool(true))])),
    ])),
]));
```

