# Univec Elixir SDK Reference

Complete API reference for the Univec Elixir SDK.


## Univec

### Constructor

```elixir
sdk = Univec.new(options)
```

Create a new SDK client. `options` is a struct value node — build one from a
native map with `Univec.Helpers.deep/1`.

**Options:**

| Name | Type | Description |
| --- | --- | --- |
| `apikey` | `String.t()` | API key for authentication. |
| `base` | `String.t()` | Base URL for API requests. |
| `prefix` | `String.t()` | URL prefix appended after base. |
| `suffix` | `String.t()` | URL suffix appended after path. |
| `headers` | `map()` | Custom headers for all requests. |
| `feature` | `map()` | Feature configuration. |
| `system` | `map()` | System overrides (e.g. custom fetch). |


### Constructors

#### `Univec.test(testopts \\ nil, sdkopts \\ nil)`

Create a test client with mock features active. Both arguments may be `nil`.

```elixir
sdk = Univec.test()
```


### Functions

#### `Univec.convert(client, entopts \\ nil)`

Create a `Univec.Entity.Convert` handle.

#### `Univec.embed(client, entopts \\ nil)`

Create a `Univec.Entity.Embed` handle.

#### `Univec.ephemeral_key(client, entopts \\ nil)`

Create a `Univec.Entity.EphemeralKey` handle.

#### `Univec.model(client, entopts \\ nil)`

Create a `Univec.Entity.Model` handle.

#### `options_map(client) :: map()`

Return a deep copy of the current SDK options.

#### `get_utility(client) :: map()`

Return the SDK utility node.

#### `direct(client, fetchargs) :: map()`

Make a direct HTTP request to any API endpoint. Returns a result node with
`ok`, `status`, `headers`, and `data` (or `err` on failure). This escape
hatch never raises — branch on `Voxgig.Struct.getprop(result, "ok")`.

**fetchargs keys:**

| Key | Type | Description |
| --- | --- | --- |
| `path` | `String.t()` | URL path with optional `{param}` placeholders. |
| `method` | `String.t()` | HTTP method (default: `"GET"`). |
| `params` | `map()` | Path parameter values. |
| `query` | `map()` | Query string parameters. |
| `headers` | `map()` | Request headers (merged with defaults). |
| `body` | `any()` | Request body (maps are JSON-serialized). |

#### `prepare(client, fetchargs) :: map()`

Prepare a fetch definition without sending. Returns the `fetchdef` and raises
on error.


---

## Univec.Entity.Convert

```elixir
convert = Univec.convert(sdk)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String.t()` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `list()` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String.t()` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String.t()` | Yes | Model space to translate into. |
| `texts` | `list()` | Yes | Texts to embed and translate. |

### Operations

#### `create(entity, reqdata, ctrl \\ nil) :: map()`

Create a new entity with the given data. Returns the created entity data and raises on error.

```elixir
record = Univec.Entity.Convert.create(convert, Univec.Helpers.deep(%{
  "bridge_model" => "example_bridge_model",  # String.t()
  "embeddings" => [],  # list()
  "source_model" => "example_source_model",  # String.t()
  "target_model" => "example_target_model",  # String.t()
  "texts" => [],  # list()
}))
```

### Common Functions

#### `data_get(entity) :: map()`

Get the entity data.

#### `data_set(entity, data)`

Set the entity data.

#### `match_get(entity) :: map()`

Get the entity match criteria.

#### `match_set(entity, match)`

Set the entity match criteria.

#### `make(entity) :: entity`

Create a new `Univec.Entity.Convert` handle with the same options.

#### `get_name(entity) :: String.t()`

Return the entity name.


---

## Univec.Entity.Embed

```elixir
embed = Univec.embed(sdk)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `list()` | Yes | One vector per input text, in input order. |
| `model` | `String.t()` | Yes | Model that produced the vectors. |
| `texts` | `list()` | Yes | Texts to embed. |

### Operations

#### `create(entity, reqdata, ctrl \\ nil) :: map()`

Create a new entity with the given data. Returns the created entity data and raises on error.

```elixir
record = Univec.Entity.Embed.create(embed, Univec.Helpers.deep(%{
  "embeddings" => [],  # list()
  "model" => "example_model",  # String.t()
  "texts" => [],  # list()
}))
```

### Common Functions

#### `data_get(entity) :: map()`

Get the entity data.

#### `data_set(entity, data)`

Set the entity data.

#### `match_get(entity) :: map()`

Get the entity match criteria.

#### `match_set(entity, match)`

Set the entity match criteria.

#### `make(entity) :: entity`

Create a new `Univec.Entity.Embed` handle with the same options.

#### `get_name(entity) :: String.t()`

Return the entity name.


---

## Univec.Entity.EphemeralKey

```elixir
ephemeral_key = Univec.ephemeral_key(sdk)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `integer()` | Yes | Calls permitted per day. |
| `dailyUsed` | `integer()` | Yes | Calls already used today. |
| `key` | `String.t()` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String.t()` | Yes | When the daily allowance resets. |

### Operations

#### `create(entity, reqdata, ctrl \\ nil) :: map()`

Create a new entity with the given data. Returns the created entity data and raises on error.

```elixir
record = Univec.Entity.EphemeralKey.create(ephemeral_key, Univec.Helpers.deep(%{
  "dailyLimit" => 1,  # integer()
  "dailyUsed" => 1,  # integer()
  "key" => "example_key",  # String.t()
  "resetsAt" => "example_resetsAt",  # String.t()
}))
```

### Common Functions

#### `data_get(entity) :: map()`

Get the entity data.

#### `data_set(entity, data)`

Set the entity data.

#### `match_get(entity) :: map()`

Get the entity match criteria.

#### `match_set(entity, match)`

Set the entity match criteria.

#### `make(entity) :: entity`

Create a new `Univec.Entity.EphemeralKey` handle with the same options.

#### `get_name(entity) :: String.t()`

Return the entity name.


---

## Univec.Entity.Model

```elixir
model = Univec.model(sdk)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `map()` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String.t()` | No | Hardware backend, e.g. |
| `modelCard` | `map()` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String.t()` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String.t()` | Yes | Model identifier used in requests. |
| `sequenceLen` | `integer()` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `integer()` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String.t()` | No | Convert models only: the source model space. |
| `targetDim` | `integer()` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String.t()` | Yes | The model space produced. |

### Operations

#### `list(entity, reqmatch \\ nil, ctrl \\ nil) :: list()`

List entities matching the given criteria. The match is optional — call `list(entity)` to list all records. Returns a list and raises on error.

```elixir
records = Univec.Entity.Model.list(model)
```

### Common Functions

#### `data_get(entity) :: map()`

Get the entity data.

#### `data_set(entity, data)`

Set the entity data.

#### `match_get(entity) :: map()`

Get the entity match criteria.

#### `match_set(entity, match)`

Set the entity match criteria.

#### `make(entity) :: entity`

Create a new `Univec.Entity.Model` handle with the same options.

#### `get_name(entity) :: String.t()`

Return the entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```elixir
sdk = Univec.new(Univec.Helpers.deep(%{
  "feature" => %{
    "test" => %{"active" => true},
  }
}))
```

