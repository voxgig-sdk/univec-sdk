# Univec Lua SDK Reference

Complete API reference for the Univec Lua SDK.


## UnivecSDK

### Constructor

```lua
local sdk = require("univec_sdk")
local client = sdk.new(options)
```

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `table` | SDK configuration options. |
| `options.apikey` | `string` | API key for authentication. |
| `options.base` | `string` | Base URL for API requests. |
| `options.prefix` | `string` | URL prefix appended after base. |
| `options.suffix` | `string` | URL suffix appended after path. |
| `options.headers` | `table` | Custom headers for all requests. |
| `options.feature` | `table` | Feature configuration. |
| `options.system` | `table` | System overrides (e.g. custom fetch). |


### Static Methods

#### `sdk.test(testopts?, sdkopts?)`

Create a test client with mock features active. Both arguments are optional.

```lua
local client = sdk.test()
```


### Instance Methods

#### `Convert(data)`

Create a new `Convert` entity instance. Pass `nil` for no initial data.

#### `Embed(data)`

Create a new `Embed` entity instance. Pass `nil` for no initial data.

#### `EphemeralKey(data)`

Create a new `EphemeralKey` entity instance. Pass `nil` for no initial data.

#### `Model(data)`

Create a new `Model` entity instance. Pass `nil` for no initial data.

#### `options_map() -> table`

Return a deep copy of the current SDK options.

#### `get_utility() -> Utility`

Return a copy of the SDK utility object.

#### `direct(fetchargs) -> table, err`

Make a direct HTTP request to any API endpoint.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs.path` | `string` | URL path with optional `{param}` placeholders. |
| `fetchargs.method` | `string` | HTTP method (default: `"GET"`). |
| `fetchargs.params` | `table` | Path parameter values for `{param}` substitution. |
| `fetchargs.query` | `table` | Query string parameters. |
| `fetchargs.headers` | `table` | Request headers (merged with defaults). |
| `fetchargs.body` | `any` | Request body (tables are JSON-serialized). |
| `fetchargs.ctrl` | `table` | Control options (e.g. `{ explain = true }`). |

**Returns:** `table, err`

#### `prepare(fetchargs) -> table, err`

Prepare a fetch definition without sending the request. Accepts the
same parameters as `direct()`.

**Returns:** `table, err`


---

## ConvertEntity

```lua
local convert = client:Convert(nil)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `string` | Yes |  |
| `data` | `table` | Yes |  |
| `embedding` | `table` | Yes |  |
| `source_model` | `string` | Yes |  |
| `success` | `boolean` | Yes |  |
| `target_model` | `string` | Yes |  |
| `text` | `table` | Yes |  |

### Operations

#### `create(reqdata, ctrl) -> any, err`

Create a new entity with the given data.

```lua
local result, err = client:Convert():create({
  bridge_model = --[[ string ]],
  data = --[[ table ]],
  embedding = --[[ table ]],
  source_model = --[[ string ]],
  success = --[[ boolean ]],
  target_model = --[[ string ]],
  text = --[[ table ]],
})
```

### Common Methods

#### `data_get() -> table`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get() -> table`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make() -> Entity`

Create a new `ConvertEntity` instance with the same client and
options.

#### `get_name() -> string`

Return the entity name.


---

## EmbedEntity

```lua
local embed = client:Embed(nil)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `data` | `table` | Yes |  |
| `model` | `string` | Yes |  |
| `success` | `boolean` | Yes |  |
| `text` | `table` | Yes |  |

### Operations

#### `create(reqdata, ctrl) -> any, err`

Create a new entity with the given data.

```lua
local result, err = client:Embed():create({
  data = --[[ table ]],
  model = --[[ string ]],
  success = --[[ boolean ]],
  text = --[[ table ]],
})
```

### Common Methods

#### `data_get() -> table`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get() -> table`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make() -> Entity`

Create a new `EmbedEntity` instance with the same client and
options.

#### `get_name() -> string`

Return the entity name.


---

## EphemeralKeyEntity

```lua
local ephemeral_key = client:EphemeralKey(nil)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `data` | `table` | Yes |  |
| `success` | `boolean` | Yes |  |

### Operations

#### `create(reqdata, ctrl) -> any, err`

Create a new entity with the given data.

```lua
local result, err = client:EphemeralKey():create({
  data = --[[ table ]],
  success = --[[ boolean ]],
})
```

### Common Methods

#### `data_get() -> table`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get() -> table`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make() -> Entity`

Create a new `EphemeralKeyEntity` instance with the same client and
options.

#### `get_name() -> string`

Return the entity name.


---

## ModelEntity

```lua
local model = client:Model(nil)
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `table` | No |  |
| `execution_provider` | `string` | No |  |
| `model_card` | `table` | No |  |
| `model_type` | `string` | Yes |  |
| `name` | `string` | Yes |  |
| `sequence_len` | `number` | No |  |
| `source_dim` | `number` | No |  |
| `source_model` | `string` | No |  |
| `target_dim` | `number` | Yes |  |
| `target_model` | `string` | Yes |  |

### Operations

#### `list(reqmatch, ctrl) -> any, err`

List entities matching the given criteria. Returns an array.

```lua
local results, err = client:Model():list()
```

### Common Methods

#### `data_get() -> table`

Get the entity data. Returns a copy of the current data.

#### `data_set(data)`

Set the entity data.

#### `match_get() -> table`

Get the entity match criteria.

#### `match_set(match)`

Set the entity match criteria.

#### `make() -> Entity`

Create a new `ModelEntity` instance with the same client and
options.

#### `get_name() -> string`

Return the entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```lua
local client = sdk.new({
  feature = {
    test = { active = true },
  },
})
```

