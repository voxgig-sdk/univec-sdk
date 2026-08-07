# Univec JavaScript SDK Reference

Complete API reference for the Univec JavaScript SDK.


## UnivecSDK

### Constructor

```ts
new UnivecSDK(options?: object)
```

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `object` | SDK configuration options. |
| `options.apikey` | `string` | API key for authentication. |
| `options.base` | `string` | Base URL for API requests. |
| `options.prefix` | `string` | URL prefix appended after base. |
| `options.suffix` | `string` | URL suffix appended after path. |
| `options.headers` | `object` | Custom headers for all requests. |
| `options.feature` | `object` | Feature configuration. |
| `options.system` | `object` | System overrides (e.g. custom fetch). |


### Static Methods

#### `UnivecSDK.test(testopts?, sdkopts?)`

Create a test client with mock features active.

```ts
const client = UnivecSDK.test()
```

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `testopts` | `object` | Test feature options. |
| `sdkopts` | `object` | Additional SDK options merged with test defaults. |

**Returns:** `UnivecSDK` instance in test mode.


### Instance Methods

#### `Convert(data?: object)`

Create a new `Convert` entity instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `data` | `object` | Initial entity data. |

**Returns:** `ConvertEntity` instance.

#### `Embed(data?: object)`

Create a new `Embed` entity instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `data` | `object` | Initial entity data. |

**Returns:** `EmbedEntity` instance.

#### `EphemeralKey(data?: object)`

Create a new `EphemeralKey` entity instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `data` | `object` | Initial entity data. |

**Returns:** `EphemeralKeyEntity` instance.

#### `Model(data?: object)`

Create a new `Model` entity instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `data` | `object` | Initial entity data. |

**Returns:** `ModelEntity` instance.

#### `options()`

Return a deep copy of the current SDK options.

**Returns:** `object`

#### `utility()`

Return a copy of the SDK utility object.

**Returns:** `object`

#### `direct(fetchargs?: object)`

Make a direct HTTP request to any API endpoint.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs.path` | `string` | URL path with optional `{param}` placeholders. |
| `fetchargs.method` | `string` | HTTP method (default: `GET`). |
| `fetchargs.params` | `object` | Path parameter values for `{param}` substitution. |
| `fetchargs.query` | `object` | Query string parameters. |
| `fetchargs.headers` | `object` | Request headers (merged with defaults). |
| `fetchargs.body` | `any` | Request body (objects are JSON-serialized). |
| `fetchargs.ctrl` | `object` | Control options (e.g. `{ explain: true }`). |

**Returns:** `Promise<{ ok, status, headers, data } | Error>`

#### `prepare(fetchargs?: object)`

Prepare a fetch definition without sending the request. Accepts the
same parameters as `direct()`.

**Returns:** `Promise<{ url, method, headers, body } | Error>`

#### `tester(testopts?, sdkopts?)`

Alias for `UnivecSDK.test()`.

**Returns:** `UnivecSDK` instance in test mode.


---

## ConvertEntity

```ts
const convert = client.Convert()
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `string` | Yes |  |
| `data` | `Object` | Yes |  |
| `embedding` | `Array` | Yes |  |
| `source_model` | `string` | Yes |  |
| `success` | `boolean` | Yes |  |
| `target_model` | `string` | Yes |  |
| `text` | `Array` | Yes |  |

### Operations

#### `create(data: object, ctrl?: object)`

Create a new entity with the given data.

```ts
const result = await client.Convert().create({
  bridge_model: 'example_bridge_model',
  data: {},
  embedding: [],
  source_model: 'example_source_model',
  success: true,
  target_model: 'example_target_model',
  text: [],
})
```

### Common Methods

#### `data(data?: object)`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `match(match?: object)`

Get or set the entity match criteria. Works the same as `data()`.

#### `make()`

Create a new `ConvertEntity` instance with the same client and
options.

#### `client()`

Return the parent `UnivecSDK` instance.

#### `entopts()`

Return a copy of the entity options.


---

## EmbedEntity

```ts
const embed = client.Embed()
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `data` | `Object` | Yes |  |
| `model` | `string` | Yes |  |
| `success` | `boolean` | Yes |  |
| `text` | `Array` | Yes |  |

### Operations

#### `create(data: object, ctrl?: object)`

Create a new entity with the given data.

```ts
const result = await client.Embed().create({
  data: {},
  model: 'example_model',
  success: true,
  text: [],
})
```

### Common Methods

#### `data(data?: object)`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `match(match?: object)`

Get or set the entity match criteria. Works the same as `data()`.

#### `make()`

Create a new `EmbedEntity` instance with the same client and
options.

#### `client()`

Return the parent `UnivecSDK` instance.

#### `entopts()`

Return a copy of the entity options.


---

## EphemeralKeyEntity

```ts
const ephemeral_key = client.EphemeralKey()
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `data` | `Object` | Yes |  |
| `success` | `boolean` | Yes |  |

### Operations

#### `create(data: object, ctrl?: object)`

Create a new entity with the given data.

```ts
const result = await client.EphemeralKey().create({
  data: {},
  success: true,
})
```

### Common Methods

#### `data(data?: object)`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `match(match?: object)`

Get or set the entity match criteria. Works the same as `data()`.

#### `make()`

Create a new `EphemeralKeyEntity` instance with the same client and
options.

#### `client()`

Return the parent `UnivecSDK` instance.

#### `entopts()`

Return a copy of the entity options.


---

## ModelEntity

```ts
const model = client.Model()
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Object` | No |  |
| `execution_provider` | `string` | No |  |
| `model_card` | `Object` | No |  |
| `model_type` | `string` | Yes |  |
| `name` | `string` | Yes |  |
| `sequence_len` | `number` | No |  |
| `source_dim` | `number` | No |  |
| `source_model` | `string` | No |  |
| `target_dim` | `number` | Yes |  |
| `target_model` | `string` | Yes |  |

### Operations

#### `list(match: object, ctrl?: object)`

List entities matching the given criteria. Returns an array.

```ts
const results = await client.Model().list()
```

### Common Methods

#### `data(data?: object)`

Get or set the entity data. When called with data, sets the entity's
internal data and returns the current data. When called without
arguments, returns a copy of the current data.

#### `match(match?: object)`

Get or set the entity match criteria. Works the same as `data()`.

#### `make()`

Create a new `ModelEntity` instance with the same client and
options.

#### `client()`

Return the parent `UnivecSDK` instance.

#### `entopts()`

Return a copy of the entity options.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```ts
const client = new UnivecSDK({
  feature: {
    test: { active: true },
  }
})
```

