# Univec PHP SDK Reference

Complete API reference for the Univec PHP SDK.


## UnivecSDK

### Constructor

```php
require_once __DIR__ . '/univec_sdk.php';

$client = new UnivecSDK($options);
```

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `$options` | `array` | SDK configuration options. |
| `$options["apikey"]` | `string` | API key for authentication. |
| `$options["base"]` | `string` | Base URL for API requests. |
| `$options["prefix"]` | `string` | URL prefix appended after base. |
| `$options["suffix"]` | `string` | URL suffix appended after path. |
| `$options["headers"]` | `array` | Custom headers for all requests. |
| `$options["feature"]` | `array` | Feature configuration. |
| `$options["system"]` | `array` | System overrides (e.g. custom fetch). |


### Static Methods

#### `UnivecSDK::test($testopts = null, $sdkopts = null)`

Create a test client with mock features active. Both arguments may be `null`.

```php
$client = UnivecSDK::test();
```


### Instance Methods

#### `Convert($data = null)`

Create a new `ConvertEntity` instance. Pass `null` for no initial data.

#### `Embed($data = null)`

Create a new `EmbedEntity` instance. Pass `null` for no initial data.

#### `EphemeralKey($data = null)`

Create a new `EphemeralKeyEntity` instance. Pass `null` for no initial data.

#### `Model($data = null)`

Create a new `ModelEntity` instance. Pass `null` for no initial data.

#### `options_map(): array`

Return a deep copy of the current SDK options.

#### `get_utility(): UnivecUtility`

Return a copy of the SDK utility object.

#### `direct(array $fetchargs = []): array`

Make a direct HTTP request to any API endpoint. This is the raw-HTTP escape
hatch: it does **not** throw. It returns a result array
`["ok" => bool, "status" => int, "headers" => array, "data" => mixed]`, or
`["ok" => false, "err" => \Exception]` on failure. Branch on `$result["ok"]`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `$fetchargs["path"]` | `string` | URL path with optional `{param}` placeholders. |
| `$fetchargs["method"]` | `string` | HTTP method (default: `"GET"`). |
| `$fetchargs["params"]` | `array` | Path parameter values for `{param}` substitution. |
| `$fetchargs["query"]` | `array` | Query string parameters. |
| `$fetchargs["headers"]` | `array` | Request headers (merged with defaults). |
| `$fetchargs["body"]` | `mixed` | Request body (arrays are JSON-serialized). |
| `$fetchargs["ctrl"]` | `array` | Control options. |

**Returns:** `array` — the result dict (see above); never throws.

#### `prepare(array $fetchargs = []): mixed`

Prepare a fetch definition without sending the request. Returns the
`$fetchdef` array. Throws on error.


---

## ConvertEntity

```php
$convert = $client->Convert();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `string` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `array` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `string` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `string` | Yes | Model space to translate into. |
| `texts` | `array` | Yes | Texts to embed and translate. |

### Operations

#### `create(array $reqdata, ?array $ctrl = null): mixed`

Create a new entity with the given data. Throws on error.

```php
$result = $client->Convert()->create([
  "bridge_model" => null, // string
  "embeddings" => null, // array
  "source_model" => null, // string
  "target_model" => null, // string
  "texts" => null, // array
]);
```

### Common Methods

#### `data_get(): array`

Get the entity data. Returns a copy of the current data.

#### `data_set($data): void`

Set the entity data.

#### `match_get(): array`

Get the entity match criteria.

#### `match_set($match): void`

Set the entity match criteria.

#### `make(): ConvertEntity`

Create a new `ConvertEntity` instance with the same client and
options.

#### `get_name(): string`

Return the entity name.


---

## EmbedEntity

```php
$embed = $client->Embed();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `array` | Yes | One vector per input text, in input order. |
| `model` | `string` | Yes | Model that produced the vectors. |
| `texts` | `array` | Yes | Texts to embed. |

### Operations

#### `create(array $reqdata, ?array $ctrl = null): mixed`

Create a new entity with the given data. Throws on error.

```php
$result = $client->Embed()->create([
  "embeddings" => null, // array
  "model" => null, // string
  "texts" => null, // array
]);
```

### Common Methods

#### `data_get(): array`

Get the entity data. Returns a copy of the current data.

#### `data_set($data): void`

Set the entity data.

#### `match_get(): array`

Get the entity match criteria.

#### `match_set($match): void`

Set the entity match criteria.

#### `make(): EmbedEntity`

Create a new `EmbedEntity` instance with the same client and
options.

#### `get_name(): string`

Return the entity name.


---

## EphemeralKeyEntity

```php
$ephemeral_key = $client->EphemeralKey();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `int` | Yes | Calls permitted per day. |
| `dailyUsed` | `int` | Yes | Calls already used today. |
| `key` | `string` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `string` | Yes | When the daily allowance resets. |

### Operations

#### `create(array $reqdata, ?array $ctrl = null): mixed`

Create a new entity with the given data. Throws on error.

```php
$result = $client->EphemeralKey()->create([
  "dailyLimit" => null, // int
  "dailyUsed" => null, // int
  "key" => null, // string
  "resetsAt" => null, // string
]);
```

### Common Methods

#### `data_get(): array`

Get the entity data. Returns a copy of the current data.

#### `data_set($data): void`

Set the entity data.

#### `match_get(): array`

Get the entity match criteria.

#### `match_set($match): void`

Set the entity match criteria.

#### `make(): EphemeralKeyEntity`

Create a new `EphemeralKeyEntity` instance with the same client and
options.

#### `get_name(): string`

Return the entity name.


---

## ModelEntity

```php
$model = $client->Model();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `array` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `string` | No | Hardware backend, e.g. |
| `modelCard` | `array` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `string` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `string` | Yes | Model identifier used in requests. |
| `sequenceLen` | `int` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `int` | No | Convert models only: source vector dimension. |
| `sourceModel` | `string` | No | Convert models only: the source model space. |
| `targetDim` | `int` | Yes | Dimension of the produced vectors. |
| `targetModel` | `string` | Yes | The model space produced. |

### Operations

#### `list(?array $reqmatch = null, ?array $ctrl = null): mixed`

List entities matching the given criteria (call with no argument to list all). Returns an array. Throws on error.

```php
$results = $client->Model()->list();
```

### Common Methods

#### `data_get(): array`

Get the entity data. Returns a copy of the current data.

#### `data_set($data): void`

Set the entity data.

#### `match_get(): array`

Get the entity match criteria.

#### `match_set($match): void`

Set the entity match criteria.

#### `make(): ModelEntity`

Create a new `ModelEntity` instance with the same client and
options.

#### `get_name(): string`

Return the entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `audit` | 0.0.1 | Structured audit trail of operations |
| `cache` | 0.0.1 | Response caching for safe read requests |
| `clienttrack` | 0.0.1 | Client identity and per-request correlation headers |
| `cost` | 0.0.1 | Cost tracking and spend budget for API calls |
| `debug` | 0.0.1 | Request/response capture ring buffer for debugging |
| `idempotency` | 0.0.1 | Idempotency keys for safe retries of mutating operations |
| `log` | 0.0.1 | Structured request and response logging |
| `metrics` | 0.0.1 | Statistics capture: per-operation counters and latency |
| `netsim` | 0.0.1 | Network behaviour simulation for offline testing (latency, failures, outages) |
| `paging` | 0.0.1 | Pagination signals for list operations |
| `proxy` | 0.0.1 | Outbound HTTP(S) proxy routing |
| `ratelimit` | 0.0.1 | Client-side rate limiting via a token bucket |
| `rbac` | 0.0.1 | Client-side role/permission enforcement |
| `retry` | 0.0.1 | Automatic retry of transient failures with exponential backoff |
| `streaming` | 0.0.1 | Incremental streaming of list results via async iteration |
| `telemetry` | 0.0.1 | Distributed tracing spans with W3C trace-context propagation |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |
| `timeout` | 0.0.1 | Per-request timeout with transport abort |


Features are activated via the `feature` option:

```php
$client = new UnivecSDK([
  "feature" => [
    "audit" => ["active" => true],
    "cache" => ["active" => true],
    "clienttrack" => ["active" => true],
    "cost" => ["active" => true],
    "debug" => ["active" => true],
    "idempotency" => ["active" => true],
    "log" => ["active" => true],
    "metrics" => ["active" => true],
    "netsim" => ["active" => true],
    "paging" => ["active" => true],
    "proxy" => ["active" => true],
    "ratelimit" => ["active" => true],
    "rbac" => ["active" => true],
    "retry" => ["active" => true],
    "streaming" => ["active" => true],
    "telemetry" => ["active" => true],
    "test" => ["active" => true],
    "timeout" => ["active" => true],
  ],
]);
```

