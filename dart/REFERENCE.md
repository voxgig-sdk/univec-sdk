# Univec Dart SDK Reference

Complete API reference for the Univec Dart SDK.

## UnivecSDK

### Constructor

```dart
import 'package:univec_sdk/UnivecSDK.dart';

final client = UnivecSDK(options);
```

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `Map` | SDK configuration options. |
| `options['apikey']` | `String` | API key for authentication. |
| `options['base']` | `String` | Base URL for API requests. |
| `options['prefix']` | `String` | URL prefix appended after base. |
| `options['suffix']` | `String` | URL suffix appended after path. |
| `options['headers']` | `Map` | Custom headers for all requests. |
| `options['feature']` | `Map` | Feature configuration. |
| `options['system']` | `Map` | System overrides (e.g. custom fetch). |


### Static Methods

#### `UnivecSDK.test([testopts, sdkopts])`

Create a test client with mock features active. Both arguments may be `null`.

```dart
final client = UnivecSDK.test();
```


### Instance Methods

#### `Convert([entopts])`

Create a new `ConvertEntity` instance. Pass no argument for no initial data.

#### `Embed([entopts])`

Create a new `EmbedEntity` instance. Pass no argument for no initial data.

#### `EphemeralKey([entopts])`

Create a new `EphemeralKeyEntity` instance. Pass no argument for no initial data.

#### `Model([entopts])`

Create a new `ModelEntity` instance. Pass no argument for no initial data.

#### `options() -> Map`

Return a deep copy of the current SDK options.

#### `utility() -> Utility`

Return the SDK utility object.

#### `direct([fetchargs]) -> Future<Map>`

Make a direct HTTP request to any API endpoint. Returns a result `Map` with `ok`, `status`, `headers`, and `data` (or `err` on failure). This escape hatch never throws — branch on `result['ok']`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `fetchargs['path']` | `String` | URL path with optional `{param}` placeholders. |
| `fetchargs['method']` | `String` | HTTP method (default: `'GET'`). |
| `fetchargs['params']` | `Map` | Path parameter values. |
| `fetchargs['query']` | `Map` | Query string parameters. |
| `fetchargs['headers']` | `Map` | Request headers (merged with defaults). |
| `fetchargs['body']` | `dynamic` | Request body (maps are JSON-serialized). |

**Returns:** `Future<Map>`

#### `prepare([fetchargs]) -> Future`

Prepare a fetch definition without sending. Returns the `fetchdef` (or an error value on failure).


---

## ConvertEntity

```dart
final convert = client.Convert();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `String` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `List<dynamic>` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Yes | Model space to translate into. |
| `texts` | `List<dynamic>` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata, [ctrl]) -> Future<dynamic>`

Create a new entity with the given data. Returns the created entity data and throws on error.

```dart
final result = await client.Convert().create({
  'bridge_model': 'example_bridge_model',  // String
  'embeddings': <dynamic>[],  // List<dynamic>
  'source_model': 'example_source_model',  // String
  'target_model': 'example_target_model',  // String
  'texts': <dynamic>[],  // List<dynamic>
});
```

### Common Methods

#### `data([d]) -> Map`

Get the entity data, or set it when passed an argument.

#### `match([m]) -> Map`

Get the entity match criteria, or set it when passed an argument.

#### `make() -> Entity`

Create a new `ConvertEntity` instance with the same options.

#### `entopts() -> Map`

Return the entity options.


---

## EmbedEntity

```dart
final embed = client.Embed();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `List<dynamic>` | Yes | One vector per input text, in input order. |
| `model` | `String` | Yes | Model that produced the vectors. |
| `texts` | `List<dynamic>` | Yes | Texts to embed. |

### Operations

#### `create(reqdata, [ctrl]) -> Future<dynamic>`

Create a new entity with the given data. Returns the created entity data and throws on error.

```dart
final result = await client.Embed().create({
  'embeddings': <dynamic>[],  // List<dynamic>
  'model': 'example_model',  // String
  'texts': <dynamic>[],  // List<dynamic>
});
```

### Common Methods

#### `data([d]) -> Map`

Get the entity data, or set it when passed an argument.

#### `match([m]) -> Map`

Get the entity match criteria, or set it when passed an argument.

#### `make() -> Entity`

Create a new `EmbedEntity` instance with the same options.

#### `entopts() -> Map`

Return the entity options.


---

## EphemeralKeyEntity

```dart
final ephemeral_key = client.EphemeralKey();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `int` | Yes | Calls permitted per day. |
| `dailyUsed` | `int` | Yes | Calls already used today. |
| `key` | `String` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata, [ctrl]) -> Future<dynamic>`

Create a new entity with the given data. Returns the created entity data and throws on error.

```dart
final result = await client.EphemeralKey().create({
  'dailyLimit': 1,  // int
  'dailyUsed': 1,  // int
  'key': 'example_key',  // String
  'resetsAt': 'example_resetsAt',  // String
});
```

### Common Methods

#### `data([d]) -> Map`

Get the entity data, or set it when passed an argument.

#### `match([m]) -> Map`

Get the entity match criteria, or set it when passed an argument.

#### `make() -> Entity`

Create a new `EphemeralKeyEntity` instance with the same options.

#### `entopts() -> Map`

Return the entity options.


---

## ModelEntity

```dart
final model = client.Model();
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Map<String, dynamic>` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | No | Hardware backend, e.g. |
| `modelCard` | `Map<String, dynamic>` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Yes | Model identifier used in requests. |
| `sequenceLen` | `int` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `int` | No | Convert models only: source vector dimension. |
| `sourceModel` | `String` | No | Convert models only: the source model space. |
| `targetDim` | `int` | Yes | Dimension of the produced vectors. |
| `targetModel` | `String` | Yes | The model space produced. |

### Operations

#### `list([reqmatch, ctrl]) -> Future<List>`

List entities matching the given criteria. The match is optional — call `list()` with no argument to list all records. Returns a list of entity instances and throws on error.

```dart
final results = await client.Model().list();
for (final model in results) {
  print(model.data());
}
```

### Common Methods

#### `data([d]) -> Map`

Get the entity data, or set it when passed an argument.

#### `match([m]) -> Map`

Get the entity match criteria, or set it when passed an argument.

#### `make() -> Entity`

Create a new `ModelEntity` instance with the same options.

#### `entopts() -> Map`

Return the entity options.


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

```dart
final client = UnivecSDK({
  'feature': {
    'audit': {'active': true},
    'cache': {'active': true},
    'clienttrack': {'active': true},
    'cost': {'active': true},
    'debug': {'active': true},
    'idempotency': {'active': true},
    'log': {'active': true},
    'metrics': {'active': true},
    'netsim': {'active': true},
    'paging': {'active': true},
    'proxy': {'active': true},
    'ratelimit': {'active': true},
    'rbac': {'active': true},
    'retry': {'active': true},
    'streaming': {'active': true},
    'telemetry': {'active': true},
    'test': {'active': true},
    'timeout': {'active': true},
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

