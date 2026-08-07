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
| `bridge_model` | `string` | Yes |  |
| `data` | `array` | Yes |  |
| `embedding` | `array` | Yes |  |
| `source_model` | `string` | Yes |  |
| `success` | `bool` | Yes |  |
| `target_model` | `string` | Yes |  |
| `text` | `array` | Yes |  |

### Operations

#### `create(array $reqdata, ?array $ctrl = null): mixed`

Create a new entity with the given data. Throws on error.

```php
$result = $client->Convert()->create([
  "bridge_model" => null, // string
  "data" => null, // array
  "embedding" => null, // array
  "source_model" => null, // string
  "success" => null, // bool
  "target_model" => null, // string
  "text" => null, // array
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
| `data` | `array` | Yes |  |
| `model` | `string` | Yes |  |
| `success` | `bool` | Yes |  |
| `text` | `array` | Yes |  |

### Operations

#### `create(array $reqdata, ?array $ctrl = null): mixed`

Create a new entity with the given data. Throws on error.

```php
$result = $client->Embed()->create([
  "data" => null, // array
  "model" => null, // string
  "success" => null, // bool
  "text" => null, // array
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
| `data` | `array` | Yes |  |
| `success` | `bool` | Yes |  |

### Operations

#### `create(array $reqdata, ?array $ctrl = null): mixed`

Create a new entity with the given data. Throws on error.

```php
$result = $client->EphemeralKey()->create([
  "data" => null, // array
  "success" => null, // bool
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
| `eval` | `array` | No |  |
| `execution_provider` | `string` | No |  |
| `model_card` | `array` | No |  |
| `model_type` | `string` | Yes |  |
| `name` | `string` | Yes |  |
| `sequence_len` | `int` | No |  |
| `source_dim` | `int` | No |  |
| `source_model` | `string` | No |  |
| `target_dim` | `int` | Yes |  |
| `target_model` | `string` | Yes |  |

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
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```php
$client = new UnivecSDK([
  "feature" => [
    "test" => ["active" => true],
  ],
]);
```

