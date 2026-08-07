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
| `bridge_model` | `string` | Yes |  |
| `data` | `map[string]any` | Yes |  |
| `embedding` | `[]any` | Yes |  |
| `source_model` | `string` | Yes |  |
| `success` | `bool` | Yes |  |
| `target_model` | `string` | Yes |  |
| `text` | `[]any` | Yes |  |

### Operations

#### `Create(reqdata, ctrl map[string]any) (any, error)`

Create a new entity with the given data.

```go
result, err := client.Convert(nil).Create(map[string]any{
    "bridge_model": "example_bridge_model",
    "data": map[string]any{},
    "embedding": []any{},
    "source_model": "example_source_model",
    "success": true,
    "target_model": "example_target_model",
    "text": []any{},
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
| `data` | `map[string]any` | Yes |  |
| `model` | `string` | Yes |  |
| `success` | `bool` | Yes |  |
| `text` | `[]any` | Yes |  |

### Operations

#### `Create(reqdata, ctrl map[string]any) (any, error)`

Create a new entity with the given data.

```go
result, err := client.Embed(nil).Create(map[string]any{
    "data": map[string]any{},
    "model": "example_model",
    "success": true,
    "text": []any{},
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
| `data` | `map[string]any` | Yes |  |
| `success` | `bool` | Yes |  |

### Operations

#### `Create(reqdata, ctrl map[string]any) (any, error)`

Create a new entity with the given data.

```go
result, err := client.EphemeralKey(nil).Create(map[string]any{
    "data": map[string]any{},
    "success": true,
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
| `eval` | `map[string]any` | No |  |
| `execution_provider` | `string` | No |  |
| `model_card` | `map[string]any` | No |  |
| `model_type` | `string` | Yes |  |
| `name` | `string` | Yes |  |
| `sequence_len` | `int` | No |  |
| `source_dim` | `int` | No |  |
| `source_model` | `string` | No |  |
| `target_dim` | `int` | Yes |  |
| `target_model` | `string` | Yes |  |

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
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```go
client := sdk.NewUnivecSDK(map[string]any{
    "feature": map[string]any{
        "test": map[string]any{"active": true},
    },
})
```

