# Univec JavaScript SDK



The JavaScript SDK for the Univec API — an entity-oriented client with full async/await support.

The API is exposed as capitalised, semantic **Entities** — e.g.
`client.Convert()` — each with a small set of operations (`list`, `create`)
instead of raw URL paths and query parameters. This keeps the surface
predictable and low-friction for both humans and AI agents.

> Other languages, the CLI, and MCP server live alongside this one — see
> the [top-level README](../README.md).


## Install
```js
npm install univec
```
## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.


### Create a Client

```js
const { UnivecSDK } = require('@voxgig-sdk/univec-js')

const client = new UnivecSDK({
  apikey: process.env.UNIVEC_APIKEY,
})
```

### Create a Convert

```js
const created = await client.Convert().create({
  bridge_model: 'example_bridge_model',
  data: {},
  embedding: [],
  source_model: 'example_source_model',
  success: true,
  target_model: 'example_target_model',
  text: [],
})
console.log(created)
```

### Direct API Access

Use `client.direct()` to call any API endpoint directly:

```js
const result = await client.direct({
  path: '/custom/endpoint/{id}',
  method: 'GET',
  params: { id: 'abc123' },
})

if (result.ok) {
  console.log(result.data)
}
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

```js
const result = await client.direct({
  path: '/api/resource/{id}',
  method: 'GET',
  params: { id: 'example' },
})

if (result instanceof Error) {
  throw result
}
if (result.ok) {
  console.log(result.status)  // 200
  console.log(result.data)    // response body
}
```

### Prepare a request without sending it

```js
const fetchdef = await client.prepare({
  path: '/api/resource/{id}',
  method: 'DELETE',
  params: { id: 'example' },
})

// Inspect before sending
console.log(fetchdef.url)
console.log(fetchdef.method)
console.log(fetchdef.headers)
```

### Use test mode

Create a mock client for unit testing — no server required:

```js
const client = UnivecSDK.test()

const model = await client.Model().list()
// model is a bare entity populated with mock response data
console.log(model)
```

You can also use the instance method:

```js
const client = new UnivecSDK({ apikey: '...' })
const testClient = client.tester()
```

### Retain entity state across calls

Entity instances remember their last match and data:

```js
const entity = client.Model()

// First call runs the operation and stores its result
await entity.list()

// Subsequent calls reuse the stored state
const data = entity.data()
console.log(data)
```

### Add custom middleware

Pass features via the `extend` option:

```js
const logger = {
  hooks: {
    PreRequest: (ctx) => {
      console.log('Requesting:', ctx.spec.method, ctx.spec.path)
    },
    PreResponse: (ctx) => {
      console.log('Status:', ctx.out.request?.status)
    },
  },
}

const client = new UnivecSDK({
  apikey: '...',
  extend: [logger],
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
cd js && npm test
```


## Reference

### UnivecSDK

#### Constructor

```js
new UnivecSDK(options?)
```

| Option | Type | Description |
| --- | --- | --- |
| `apikey` | `string` | API key for authentication. |
| `base` | `string` | Base URL of the API server. |
| `prefix` | `string` | URL path prefix prepended to all requests. |
| `suffix` | `string` | URL path suffix appended to all requests. |
| `feature` | `object` | Feature activation flags (e.g. `{ test: { active: true } }`). |
| `extend` | `Feature[]` | Additional feature instances to load. |

#### Methods

| Method | Returns | Description |
| --- | --- | --- |
| `options()` | `object` | Deep copy of current SDK options. |
| `utility()` | `Utility` | Deep copy of the SDK utility object. |
| `prepare(fetchargs?)` | `Promise<FetchDef>` | Build an HTTP request definition without sending it. |
| `direct(fetchargs?)` | `Promise<DirectResult>` | Build and send an HTTP request. |
| `Convert(data?)` | `ConvertEntity` | Create a Convert entity instance. |
| `Embed(data?)` | `EmbedEntity` | Create an Embed entity instance. |
| `EphemeralKey(data?)` | `EphemeralKeyEntity` | Create an EphemeralKey entity instance. |
| `Model(data?)` | `ModelEntity` | Create a Model entity instance. |
| `tester(testopts?, sdkopts?)` | `UnivecSDK` | Create a test-mode client instance. |

#### Static methods

| Method | Returns | Description |
| --- | --- | --- |
| `UnivecSDK.test(testopts?, sdkopts?)` | `UnivecSDK` | Create a test-mode client. |

### Entity interface

All entities share the same interface.

#### Methods

| Method | Signature | Description |
| --- | --- | --- |
| `list` | `list(reqmatch?, ctrl?): Promise<Entity[]>` | List entities matching the criteria. |
| `create` | `create(reqdata?, ctrl?): Promise<Entity>` | Create a new entity. |
| `data` | `data(data?: Partial<Entity>): Entity` | Get or set entity data. |
| `match` | `match(match?: Partial<Entity>): Partial<Entity>` | Get or set entity match criteria. |
| `make` | `make(): Entity` | Create a new instance with the same options. |
| `client` | `client(): UnivecSDK` | Return the parent SDK client. |
| `entopts` | `entopts(): object` | Return a copy of the entity options. |

#### Return values

Entity operations resolve to the entity data directly — there is no
result envelope:

- `create` resolves to a single entity object.
- `list` resolves to an **array** of entity objects (iterate it directly;
  there is no `.data` and no `.ok`).

On a failed request these methods **throw**, so wrap calls in
`try`/`catch` to handle errors. Only `direct()` returns the result
envelope described below.

### DirectResult shape

The `direct()` method returns:

```js
{
  ok: true,
  status: 200,
  headers: {},
  data: {}
}
```

On error, `ok` is `false` and an `err` property contains the error.

### FetchDef shape

The `prepare()` method returns:

```js
{
  url: 'string',
  method: 'string',
  headers: {},
  body: undefined
}
```

### Entities

#### Convert

| Field | Description |
| --- | --- |
| `bridge_model` |  |
| `data` |  |
| `embedding` |  |
| `source_model` |  |
| `success` |  |
| `target_model` |  |
| `text` |  |

Operations: create.

API path: `/v1/convert`

#### Embed

| Field | Description |
| --- | --- |
| `data` |  |
| `model` |  |
| `success` |  |
| `text` |  |

Operations: create.

API path: `/v1/embed`

#### EphemeralKey

| Field | Description |
| --- | --- |
| `data` |  |
| `success` |  |

Operations: create.

API path: `/v1/ephemeral/key`

#### Model

| Field | Description |
| --- | --- |
| `eval` |  |
| `execution_provider` |  |
| `model_card` |  |
| `model_type` |  |
| `name` |  |
| `sequence_len` |  |
| `source_dim` |  |
| `source_model` |  |
| `target_dim` |  |
| `target_model` |  |

Operations: list.

API path: `/v1/models`



## Entities


### Convert

Create an instance: `const convert = client.Convert()`

#### Operations

| Method | Description |
| --- | --- |
| `create(data)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `bridge_model` | `string` |  |
| `data` | `Object` |  |
| `embedding` | `Array` |  |
| `source_model` | `string` |  |
| `success` | `boolean` |  |
| `target_model` | `string` |  |
| `text` | `Array` |  |

#### Example: Create

```ts
const convert = await client.Convert().create({
  bridge_model: 'example_bridge_model',
  data: {},
  embedding: [],
  source_model: 'example_source_model',
  success: true,
  target_model: 'example_target_model',
  text: [],
})
```


### Embed

Create an instance: `const embed = client.Embed()`

#### Operations

| Method | Description |
| --- | --- |
| `create(data)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `data` | `Object` |  |
| `model` | `string` |  |
| `success` | `boolean` |  |
| `text` | `Array` |  |

#### Example: Create

```ts
const embed = await client.Embed().create({
  data: {},
  model: 'example_model',
  success: true,
  text: [],
})
```


### EphemeralKey

Create an instance: `const ephemeral_key = client.EphemeralKey()`

#### Operations

| Method | Description |
| --- | --- |
| `create(data)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `data` | `Object` |  |
| `success` | `boolean` |  |

#### Example: Create

```ts
const ephemeral_key = await client.EphemeralKey().create({
  data: {},
  success: true,
})
```


### Model

Create an instance: `const model = client.Model()`

#### Operations

| Method | Description |
| --- | --- |
| `list(match)` | List entities matching the criteria. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `eval` | `Object` |  |
| `execution_provider` | `string` |  |
| `model_card` | `Object` |  |
| `model_type` | `string` |  |
| `name` | `string` |  |
| `sequence_len` | `number` |  |
| `source_dim` | `number` |  |
| `source_model` | `string` |  |
| `target_dim` | `number` |  |
| `target_model` | `string` |  |

#### Example: List

```ts
const models = await client.Model().list()
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

### Module structure

```
univec/
├── src/
│   ├── UnivecSDK.js        # Main SDK class
│   ├── entity/             # Entity implementations
│   ├── feature/            # Built-in features (Base, Test, Log)
│   └── utility/            # Utility functions
└── test/                   # Test suites
```

Import the SDK from the package root:

```js
const { UnivecSDK } = require('@voxgig-sdk/univec-js')
```

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
