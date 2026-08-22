# Univec Elixir SDK



The Elixir SDK for the Univec API — an entity-oriented client
following idiomatic, functional Elixir conventions.

The SDK exposes the API as capitalised, semantic **Entities** — for example `Univec.convert(sdk)` — each
carrying a small, uniform set of operations (`list`, `create`) instead of raw URL
paths and query strings. You work with named resources and verbs, which
keeps the cognitive load low.

> Other languages, the CLI, and MCP server live alongside this one — see
> the [top-level README](../README.md).


## Install
This package is not yet published to [Hex](https://hex.pm). Install it from
the GitHub release tag (`elixir/vX.Y.Z`, see [Releases](https://github.com/voxgig-sdk/univec-sdk/releases))
by adding a git dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:univec, git: "https://github.com/voxgig-sdk/univec-sdk.git", tag: "elixir/vX.Y.Z"}
  ]
end
```

Or from a local source checkout:

```elixir
def deps do
  [
    {:univec, path: "../univec-sdk/elixir"}
  ]
end
```

Then run `mix deps.get`.


## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.

### 1. Create a client

```elixir
alias Univec.Helpers, as: H

sdk = Univec.new(H.deep(%{"apikey" => System.get_env("UNIVEC_APIKEY")}))
```

### 4. Create, update, and remove

```elixir
convert = Univec.convert(sdk)

# Create — returns the bare created record
created = Univec.Entity.Convert.create(convert, H.deep(%{"bridge_model" => "example_bridge_model", "embeddings" => [], "source_model" => "example_source_model", "target_model" => "example_target_model", "texts" => []}))

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

For endpoints not covered by entity operations. `direct/2` never raises —
it returns a result node you branch on with `Voxgig.Struct.getprop/2`:

```elixir
alias Voxgig.Struct, as: S
alias Univec.Helpers, as: H

result = Univec.direct(sdk, H.deep(%{
  "path" => "/api/resource/{id}",
  "method" => "GET",
  "params" => %{"id" => "example"}
}))

if S.getprop(result, "ok") do
  IO.inspect(S.getprop(result, "status"))  # 200
  IO.inspect(S.getprop(result, "data"))    # response body
else
  # A non-2xx response carries status + data (the error body); a
  # transport-level failure carries err instead.
  IO.inspect(S.getprop(result, "err"))
end
```

### Prepare a request without sending it

```elixir
alias Univec.Helpers, as: H

# prepare/2 returns the fetch definition and raises on error.
fetchdef = Univec.prepare(sdk, H.deep(%{
  "path" => "/api/resource/{id}",
  "method" => "DELETE",
  "params" => %{"id" => "example"}
}))

IO.inspect(Voxgig.Struct.getprop(fetchdef, "url"))
IO.inspect(Voxgig.Struct.getprop(fetchdef, "method"))
```

### Use test mode

Create a mock client for unit testing — no server required:

```elixir
alias Univec.Helpers, as: H

sdk = Univec.test()

# Entity ops return the bare record (raise on error).
model = Univec.model(sdk)
records = Univec.Entity.Model.list(model, H.deep(%{}))
IO.inspect(records)
```

### Use a custom fetch function

Replace the HTTP transport with your own function. It receives `(url,
fetchdef)` and returns a `{response, error}` tuple:

```elixir
alias Voxgig.Struct, as: S
alias Univec.Helpers, as: H

mock_fetch = fn _url, _fetchdef ->
  response = H.deep(%{
    "status" => 200,
    "statusText" => "OK",
    "headers" => %{},
    "json" => fn -> %{"id" => "mock01"} end
  })
  {response, nil}
end

sdk = Univec.new(H.deep(%{
  "base" => "http://localhost:8080",
  "system" => %{"fetch" => mock_fetch}
}))
```

### Run live tests

Create a `.env.local` file at the project root:

```
UNIVEC_TEST_LIVE=TRUE
UNIVEC_APIKEY=<your-key>
```

Then run:

```bash
cd elixir && mix test
```


## Reference

### Univec

```elixir
sdk = Univec.new(options)
```

Creates a new SDK client. `options` is a struct value node — build one from a
native map with `Univec.Helpers.deep/1`.

| Option | Type | Description |
| --- | --- | --- |
| `apikey` | `String.t()` | API key for authentication. |
| `base` | `String.t()` | Base URL of the API server. |
| `prefix` | `String.t()` | URL path prefix prepended to all requests. |
| `suffix` | `String.t()` | URL path suffix appended to all requests. |
| `feature` | `map()` | Feature activation flags. |
| `extend` | `list()` | Additional feature instances to load. |
| `system` | `map()` | System overrides (e.g. custom `fetch` function). |

### test

```elixir
sdk = Univec.test(testopts, sdkopts)
```

Creates a test-mode client with mock transport. Both arguments may be `nil`.

### Univec functions

| Function | Signature | Description |
| --- | --- | --- |
| `options_map` | `(client) :: map()` | Deep copy of current SDK options. |
| `get_utility` | `(client) :: map()` | The SDK utility node. |
| `prepare` | `(client, fetchargs) :: map()` | Build an HTTP request definition without sending. Raises on error. |
| `direct` | `(client, fetchargs) :: map()` | Build and send an HTTP request. Returns a result node (branch on `ok`). |
| `convert` | `(client, entopts \\ nil) :: entity` | Create a Convert entity handle. |
| `embed` | `(client, entopts \\ nil) :: entity` | Create an Embed entity handle. |
| `ephemeral_key` | `(client, entopts \\ nil) :: entity` | Create an EphemeralKey entity handle. |
| `model` | `(client, entopts \\ nil) :: entity` | Create a Model entity handle. |

### Entity interface

Every entity's `Univec.Entity.<Name>` module shares the same interface.

| Function | Signature | Description |
| --- | --- | --- |
| `list` | `(entity, reqmatch \\ nil, ctrl \\ nil) :: list()` | List entities matching the criteria. Raises on error. |
| `create` | `(entity, reqdata, ctrl \\ nil) :: map()` | Create a new entity. Raises on error. |
| `data_get` | `(entity) :: map()` | Get entity data. |
| `data_set` | `(entity, data)` | Set entity data. |
| `match_get` | `(entity) :: map()` | Get entity match criteria. |
| `match_set` | `(entity, match)` | Set entity match criteria. |
| `make` | `(entity) :: entity` | Create a new handle with the same options. |
| `get_name` | `(entity) :: String.t()` | Return the entity name. |

### Result shape

Entity operations return the bare result data (a value node — a map for
single-entity ops, a list for `list`) and raise a `Univec.Error` on
failure. Wrap calls in `try`/`rescue` to handle errors.

The `direct/2` escape hatch never raises — it returns a result node you
branch on via `Voxgig.Struct.getprop(result, "ok")`:

| Key | Type | Description |
| --- | --- | --- |
| `ok` | `boolean()` | `true` if the HTTP status is 2xx. |
| `status` | `integer()` | HTTP status code. |
| `headers` | `map()` | Response headers. |
| `data` | `any()` | Parsed JSON response body. |

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

Every operation lives on the entity's `Univec.Entity.<Name>` module and
takes an entity handle built from the client:


### Convert

Create a handle: `convert = Univec.convert(sdk)`

#### Operations

| Method | Description |
| --- | --- |
| `create(entity, data)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `bridge_model` | `String.t()` | Embed model used to vectorise the text before translation. |
| `embeddings` | `list()` | Translated vectors, in the target model's dimension. |
| `source_model` | `String.t()` | Model space the supplied vectors are currently in. |
| `target_model` | `String.t()` | Model space to translate into. |
| `texts` | `list()` | Texts to embed and translate. |

#### Example: Create

```elixir
convert = Univec.convert(sdk)
record = Univec.Entity.Convert.create(convert, Univec.Helpers.deep(%{
  "bridge_model" => "example_bridge_model",  # String.t()
  "embeddings" => [],  # list()
  "source_model" => "example_source_model",  # String.t()
  "target_model" => "example_target_model",  # String.t()
  "texts" => [],  # list()
}))
```


### Embed

Create a handle: `embed = Univec.embed(sdk)`

#### Operations

| Method | Description |
| --- | --- |
| `create(entity, data)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `list()` | One vector per input text, in input order. |
| `model` | `String.t()` | Model that produced the vectors. |
| `texts` | `list()` | Texts to embed. |

#### Example: Create

```elixir
embed = Univec.embed(sdk)
record = Univec.Entity.Embed.create(embed, Univec.Helpers.deep(%{
  "embeddings" => [],  # list()
  "model" => "example_model",  # String.t()
  "texts" => [],  # list()
}))
```


### EphemeralKey

Create a handle: `ephemeral_key = Univec.ephemeral_key(sdk)`

#### Operations

| Method | Description |
| --- | --- |
| `create(entity, data)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `dailyLimit` | `integer()` | Calls permitted per day. |
| `dailyUsed` | `integer()` | Calls already used today. |
| `key` | `String.t()` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String.t()` | When the daily allowance resets. |

#### Example: Create

```elixir
ephemeral_key = Univec.ephemeral_key(sdk)
record = Univec.Entity.EphemeralKey.create(ephemeral_key, Univec.Helpers.deep(%{
  "dailyLimit" => 1,  # integer()
  "dailyUsed" => 1,  # integer()
  "key" => "example_key",  # String.t()
  "resetsAt" => "example_resetsAt",  # String.t()
}))
```


### Model

Create a handle: `model = Univec.model(sdk)`

#### Operations

| Method | Description |
| --- | --- |
| `list(entity)` | List entities, optionally matching the given criteria. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `eval` | `map()` | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String.t()` | Hardware backend, e.g. |
| `modelCard` | `map()` | Convert models only: training provenance and architecture detail. |
| `modelType` | `String.t()` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String.t()` | Model identifier used in requests. |
| `sequenceLen` | `integer()` | Embed models only: maximum input sequence length. |
| `sourceDim` | `integer()` | Convert models only: source vector dimension. |
| `sourceModel` | `String.t()` | Convert models only: the source model space. |
| `targetDim` | `integer()` | Dimension of the produced vectors. |
| `targetModel` | `String.t()` | The model space produced. |

#### Example: List

```elixir
model = Univec.model(sdk)
records = Univec.Entity.Model.list(model)
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

### Data as struct value nodes

The Elixir SDK models every runtime object — clients, contexts, results and
record data — as reference-stable struct value nodes from the vendored
`Voxgig.Struct` library rather than as compile-time structs. This mirrors
the dynamic nature of the API and lets a feature hook mutate a shared node
that every later pipeline stage observes — the immutable-Elixir way to honour
the shared-mutable hook contract.

Build inputs from native Elixir maps with `Univec.Helpers.deep/1`,
and read fields off results with `Voxgig.Struct.getprop/2`.

### Module structure

```
elixir/
├── lib/
│   ├── univec.ex                 -- Main SDK module (entity factories)
│   ├── config.ex                 -- Resolved configuration
│   ├── features.ex               -- Feature factory
│   ├── pipeline.ex               -- Operation pipeline
│   └── univec/
│       ├── context.ex            -- Operation context
│       ├── entity_base.ex        -- Shared entity behaviour
│       ├── error.ex              -- SDK error type
│       ├── feature.ex            -- Built-in features
│       ├── helpers.ex            -- Value helpers (deep/1, ...)
│       ├── json.ex               -- JSON encode/decode
│       └── utility.ex            -- Utility functions
│   └── entity/                   -- Per-entity modules
├── mix.exs                       -- Package manifest
└── test/                         -- ExUnit suites
```

The main module `Univec` exposes the SDK constructors and one entity
factory function per entity. Call an operation on the matching
`Univec.Entity.<Name>` module.

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
