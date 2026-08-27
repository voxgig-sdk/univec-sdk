# Univec C# SDK Reference

Complete API reference for the Univec C# SDK.


## UnivecSDK

### Constructor

```csharp
using UnivecSdk;

var client = new UnivecSDK(options);
```

Create a new SDK client instance. `options` is a
`Dictionary<string, object?>`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `Dictionary` | SDK configuration options. |
| `options["apikey"]` | `string` | API key for authentication. |
| `options["base"]` | `string` | Base URL for API requests. |
| `options["prefix"]` | `string` | URL prefix appended after base. |
| `options["suffix"]` | `string` | URL suffix appended after path. |
| `options["headers"]` | `Dictionary` | Custom headers for all requests. |
| `options["feature"]` | `Dictionary` | Feature configuration. |
| `options["system"]` | `Dictionary` | System overrides (e.g. custom fetch). |


### Static Methods

#### `UnivecSDK.TestSDK(testopts = null, sdkopts = null)`

Create a test client with mock features active. Both arguments may be `null`.

```csharp
var client = UnivecSDK.TestSDK(null, null);
```


### Instance Methods

#### `Convert(entopts = null)`

Create a new `Convert` entity instance (returns
`UnivecEntityBase`). Pass `null` for no initial options.

#### `Embed(entopts = null)`

Create a new `Embed` entity instance (returns
`UnivecEntityBase`). Pass `null` for no initial options.

#### `EphemeralKey(entopts = null)`

Create a new `EphemeralKey` entity instance (returns
`UnivecEntityBase`). Pass `null` for no initial options.

#### `Model(entopts = null)`

Create a new `Model` entity instance (returns
`UnivecEntityBase`). Pass `null` for no initial options.

#### `OptionsMap() -> Dictionary`

Return a deep copy of the current SDK options.

#### `GetUtility() -> Utility`

Return a copy of the SDK utility object.

#### `Direct(fetchargs = null) -> Dictionary`

Make a direct HTTP request to any API endpoint. Returns a result
`Dictionary<string, object?>` with `ok`, `status`, `headers`, and `data`
(or `err` on failure). This escape hatch never raises — branch on
`result["ok"]`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs["path"]` | `string` | URL path with optional `{param}` placeholders. |
| `fetchargs["method"]` | `string` | HTTP method (default: `"GET"`). |
| `fetchargs["params"]` | `Dictionary` | Path parameter values. |
| `fetchargs["query"]` | `Dictionary` | Query string parameters. |
| `fetchargs["headers"]` | `Dictionary` | Request headers (merged with defaults). |
| `fetchargs["body"]` | `object?` | Request body (dictionaries are JSON-serialized). |

**Returns:** `Dictionary<string, object?>`

#### `Prepare(fetchargs = null) -> Dictionary`

Prepare a fetch definition without sending. Returns the `fetchdef` and raises on error.


---

## Convert

```csharp
var convert = client.Convert();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `string` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `List<object?>` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `string` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `string` | Yes | Model space to translate into. |
| `texts` | `List<object?>` | Yes | Texts to embed and translate. |

### Operations

#### `Create(reqdata, ctrl = null) -> object?`

Create a new entity with the given data. Returns the created entity data and raises on error.

```csharp
var result = client.Convert().Create(new Dictionary<string, object?>
{
    ["bridge_model"] = "example_bridge_model",  // string
    ["embeddings"] = new List<object?>(),  // List<object?>
    ["source_model"] = "example_source_model",  // string
    ["target_model"] = "example_target_model",  // string
    ["texts"] = new List<object?>(),  // List<object?>
});
```

### Common Methods

#### `Data(newdata = null) -> object?`

Get or set the entity data.

#### `Match(newmatch = null) -> object?`

Get or set the entity match criteria.

#### `Make() -> IEntity`

Create a new `Convert` entity instance with the same options.

#### `GetName() -> string`

Return the entity name.


---

## Embed

```csharp
var embed = client.Embed();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `List<object?>` | Yes | One vector per input text, in input order. |
| `model` | `string` | Yes | Model that produced the vectors. |
| `texts` | `List<object?>` | Yes | Texts to embed. |

### Operations

#### `Create(reqdata, ctrl = null) -> object?`

Create a new entity with the given data. Returns the created entity data and raises on error.

```csharp
var result = client.Embed().Create(new Dictionary<string, object?>
{
    ["embeddings"] = new List<object?>(),  // List<object?>
    ["model"] = "example_model",  // string
    ["texts"] = new List<object?>(),  // List<object?>
});
```

### Common Methods

#### `Data(newdata = null) -> object?`

Get or set the entity data.

#### `Match(newmatch = null) -> object?`

Get or set the entity match criteria.

#### `Make() -> IEntity`

Create a new `Embed` entity instance with the same options.

#### `GetName() -> string`

Return the entity name.


---

## EphemeralKey

```csharp
var ephemeralKey = client.EphemeralKey();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `long` | Yes | Calls permitted per day. |
| `dailyUsed` | `long` | Yes | Calls already used today. |
| `key` | `string` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `string` | Yes | When the daily allowance resets. |

### Operations

#### `Create(reqdata, ctrl = null) -> object?`

Create a new entity with the given data. Returns the created entity data and raises on error.

```csharp
var result = client.EphemeralKey().Create(new Dictionary<string, object?>
{
    ["dailyLimit"] = 1L,  // long
    ["dailyUsed"] = 1L,  // long
    ["key"] = "example_key",  // string
    ["resetsAt"] = "example_resetsAt",  // string
});
```

### Common Methods

#### `Data(newdata = null) -> object?`

Get or set the entity data.

#### `Match(newmatch = null) -> object?`

Get or set the entity match criteria.

#### `Make() -> IEntity`

Create a new `EphemeralKey` entity instance with the same options.

#### `GetName() -> string`

Return the entity name.


---

## Model

```csharp
var model = client.Model();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Dictionary<string, object?>` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `string` | No | Hardware backend, e.g. |
| `modelCard` | `Dictionary<string, object?>` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `string` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `string` | Yes | Model identifier used in requests. |
| `sequenceLen` | `long` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `long` | No | Convert models only: source vector dimension. |
| `sourceModel` | `string` | No | Convert models only: the source model space. |
| `targetDim` | `long` | Yes | Dimension of the produced vectors. |
| `targetModel` | `string` | Yes | The model space produced. |

### Operations

#### `List(reqmatch, ctrl = null) -> object?`

List entities matching the given criteria. The match is optional — call `List(null)` to list all records. Returns an aggregate list and raises on error.

```csharp
var results = client.Model().List(null);
Console.WriteLine(results);
```

### Common Methods

#### `Data(newdata = null) -> object?`

Get or set the entity data.

#### `Match(newmatch = null) -> object?`

Get or set the entity match criteria.

#### `Make() -> IEntity`

Create a new `Model` entity instance with the same options.

#### `GetName() -> string`

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

```csharp
var client = new UnivecSDK(new Dictionary<string, object?>
{
    ["feature"] = new Dictionary<string, object?>
    {
        ["audit"] = new Dictionary<string, object?> { ["active"] = true },
        ["cache"] = new Dictionary<string, object?> { ["active"] = true },
        ["clienttrack"] = new Dictionary<string, object?> { ["active"] = true },
        ["cost"] = new Dictionary<string, object?> { ["active"] = true },
        ["debug"] = new Dictionary<string, object?> { ["active"] = true },
        ["idempotency"] = new Dictionary<string, object?> { ["active"] = true },
        ["log"] = new Dictionary<string, object?> { ["active"] = true },
        ["metrics"] = new Dictionary<string, object?> { ["active"] = true },
        ["netsim"] = new Dictionary<string, object?> { ["active"] = true },
        ["paging"] = new Dictionary<string, object?> { ["active"] = true },
        ["proxy"] = new Dictionary<string, object?> { ["active"] = true },
        ["ratelimit"] = new Dictionary<string, object?> { ["active"] = true },
        ["rbac"] = new Dictionary<string, object?> { ["active"] = true },
        ["retry"] = new Dictionary<string, object?> { ["active"] = true },
        ["streaming"] = new Dictionary<string, object?> { ["active"] = true },
        ["telemetry"] = new Dictionary<string, object?> { ["active"] = true },
        ["test"] = new Dictionary<string, object?> { ["active"] = true },
        ["timeout"] = new Dictionary<string, object?> { ["active"] = true },
    },
});
```


### Configuring features

Each feature is inactive until switched on, and an SDK with no feature
configured does no feature work at all. Every option below keeps its default
unless you name it.

The array form of \`feature\` is significant: several features wrap the
transport, and the order you list them in is the order they nest.

#### Ordering

`cache`, `cost`, `netsim`, `proxy`, `ratelimit`, `retry`, `timeout` wrap the transport. Each
wraps whatever is already installed, so **activation order is nesting order**:
a feature activated later sits OUTSIDE one activated earlier, and sees the call
first.

That decides behaviour, not just sequence. \`cost\` activated before \`cache\`
sits inside it, so a response served from the cache never reaches \`cost\` and is
correctly charged nothing; reverse them and every cache hit is billed for money
that was never spent.

`audit`, `clienttrack`, `debug`, `idempotency`, `log`, `metrics`, `paging`, `rbac`, `streaming`, `telemetry`, `test` attach to pipeline hooks
rather than the transport, so their order does not affect what they observe.

#### `audit`

Structured audit trail of operations.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `actor` | `'anonymous'` |
| `max` | `1000` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.audit.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `cache`

Response caching for safe read requests.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `256` |
| `methods` | `['GET']` |
| `ttl` | `5000` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.cache.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

#### `clienttrack`

Client identity and per-request correlation headers.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `clientVersion` | `'0.0.1'` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.clienttrack.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `cost`

Cost tracking and spend budget for API calls.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `budget` | `0` |
| `currency` | `'USD'` |
| `header` | `''` |
| `onBudget` | `'warn'` |
| `path` | `''` |
| `perUnit` | `0` |
| `rates` | `{}` |
| `unit` | `0` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.cost.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

#### `debug`

Request/response capture ring buffer for debugging.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `100` |
| `redact` | `['authorization', 'cookie', 'set-cookie', 'api-key', 'apikey', 'x-api-key', 'idempotency-key']` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.debug.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `idempotency`

Idempotency keys for safe retries of mutating operations.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `header` | `'Idempotency-Key'` |
| `methods` | `['POST', 'PUT', 'PATCH', 'DELETE']` |
| `ops` | `['create', 'update', 'remove']` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.idempotency.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `log`

Structured request and response logging.

**Configuration**

| Option | Default |
|---|---|
| `active` | `true` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.log.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `metrics`

Statistics capture: per-operation counters and latency.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.metrics.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `netsim`

Network behaviour simulation for offline testing (latency, failures, outages).

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `errorTimes` | `0` |
| `failEvery` | `0` |
| `failRate` | `0` |
| `failStatus` | `503` |
| `failTimes` | `0` |
| `latency` | `0` |
| `offline` | `false` |
| `rateLimitTimes` | `0` |
| `retryAfter` | `0` |
| `seed` | `1` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.netsim.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

#### `paging`

Pagination signals for list operations.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `afterVar` | `'after'` |
| `cursorParam` | `'cursor'` |
| `firstVar` | `'first'` |
| `limitParam` | `'limit'` |
| `pageParam` | `'page'` |
| `startPage` | `1` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.paging.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `proxy`

Outbound HTTP(S) proxy routing.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `fromEnv` | `false` |
| `noProxy` | `[]` |
| `url` | `''` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.proxy.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

#### `ratelimit`

Client-side rate limiting via a token bucket.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `burst` | `5` |
| `rate` | `5` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.ratelimit.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

#### `rbac`

Client-side role/permission enforcement.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `deny` | `false` |
| `permissions` | `[]` |
| `rules` | `{}` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.rbac.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `retry`

Automatic retry of transient failures with exponential backoff.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `factor` | `2` |
| `maxDelay` | `2000` |
| `minDelay` | `50` |
| `retries` | `2` |
| `statuses` | `[408, 425, 429, 500, 502, 503, 504]` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.retry.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

#### `streaming`

Incremental streaming of list results via async iteration.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `chunkDelay` | `0` |
| `chunkSize` | `0` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.streaming.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `telemetry`

Distributed tracing spans with W3C trace-context propagation.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.telemetry.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Inactive by default: leaving it out costs nothing at runtime.

#### `test`

In-memory mock transport for testing without a live server.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.test.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Attaches to pipeline hooks, not the transport, so activation order does
  not change what it observes.
- Installs the BASE transport that the wrapping features wrap, so it must be
  activated before them.
- Inactive by default: leaving it out costs nothing at runtime.

#### `timeout`

Per-request timeout with transport abort.

**Configuration**

| Option | Default |
|---|---|
| `active` | `false` |
| `ms` | `30000` |

Options above are those the model carries a default for. A feature may
also accept callback options — a `sink` to receive each record, for
instance — which have no default and are covered in the full feature
reference.

**Usage**

Set `feature.timeout.active` to true in the client options, and override any option above in the same entry. Every option keeps
its default unless you name it.

**Considerations**

- Wraps the transport: its place in the activation order decides what it
  sees. See [Ordering](#ordering) above.
- Inactive by default: leaving it out costs nothing at runtime.

