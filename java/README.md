# Univec Java SDK



The Java SDK for the Univec API — an entity-oriented client following idiomatic Java conventions.

The SDK exposes the API as capitalised, semantic **Entities** — for example `client.convert(null)` — each
carrying a small, uniform set of operations (`list`, `create`) instead of raw URL
paths and query strings. You work with named resources and verbs, which
keeps the cognitive load low.

> Other languages, the CLI, and MCP server live alongside this one — see
> the [top-level README](../README.md).


## Install
This package is not yet published to Maven Central. Install it from the GitHub
release tag (`java/vX.Y.Z`, see [Releases](https://github.com/voxgig-sdk/univec-sdk/releases)) or
from a source checkout — build the library with Maven:

```bash
cd java && mvn install
```


## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.

### 1. Create a client

```java
import voxgig.univecsdk.core.UnivecSDK;

Map<String, Object> options = new java.util.LinkedHashMap<>();
options.put("apikey", System.getenv("UNIVEC_APIKEY"));
UnivecSDK client = new UnivecSDK(options);
```

### 4. Create, update, and remove

```java
// Create — returns the ENTITY (call data() for the record)
Object created = client.convert(null).create(Map.of("embeddings", List.of(), "source_model", "example_source_model", "target_model", "example_target_model"), null);

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

```java
Map<String, Object> result = client.direct(Map.of(
    "path", "/api/resource/{id}",
    "method", "GET",
    "params", Map.of("id", "example")));

if (Boolean.TRUE.equals(result.get("ok"))) {
    System.out.println(result.get("status"));  // 200
    System.out.println(result.get("data"));    // response body
}
else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present, so
    // read both — an absent key simply reads as null.
    System.out.println(result.get("status") + " " + result.get("err"));
}
```

### Prepare a request without sending it

```java
// prepare() returns the fetch definition and raises on error.
Map<String, Object> fetchdef = client.prepare(Map.of(
    "path", "/api/resource/{id}",
    "method", "DELETE",
    "params", Map.of("id", "example")));

System.out.println(fetchdef.get("url"));
System.out.println(fetchdef.get("method"));
System.out.println(fetchdef.get("headers"));
```

### Use test mode

Create a mock client for unit testing — no server required:

```java
UnivecSDK client = UnivecSDK.testSDK(null, null);

// Entity ops return the ENTITY and raises on error;
// call data() for the record.
Object model = client.model(null).list(null, null);
// model holds the mock response record
System.out.println(model);
```

### Use a custom fetch function

Replace the HTTP transport with your own `BiFunction`:

```java
java.util.function.BiFunction<String, Map<String, Object>, Object> mockFetch =
    (url, init) -> {
        Map<String, Object> res = new java.util.LinkedHashMap<>();
        res.put("status", 200);
        res.put("statusText", "OK");
        res.put("headers", new java.util.LinkedHashMap<String, Object>());
        res.put("json", (java.util.function.Supplier<Object>) () ->
            Map.of("id", "mock01"));
        return res;
    };

Map<String, Object> options = new java.util.LinkedHashMap<>();
options.put("base", "http://localhost:8080");
options.put("system", Map.of("fetch", mockFetch));
UnivecSDK client = new UnivecSDK(options);
```

### Run live tests

Create a `.env.local` file at the project root:

```
UNIVEC_TEST_LIVE=TRUE
UNIVEC_APIKEY=<your-key>
```

Then run:

```bash
cd java && mvn test
```


## Reference

### UnivecSDK

```java
UnivecSDK client = new UnivecSDK(options);
```

Creates a new SDK client. `options` is a `Map<String, Object>`.

| Option | Type | Description |
| --- | --- | --- |
| `apikey` | `String` | API key for authentication. |
| `base` | `String` | Base URL of the API server. |
| `prefix` | `String` | URL path prefix prepended to all requests. |
| `suffix` | `String` | URL path suffix appended to all requests. |
| `feature` | `Map` | Feature activation flags. |
| `extend` | `List` | Additional Feature instances to load. |
| `system` | `Map` | System overrides (e.g. custom `fetch` function). |

### testSDK

```java
UnivecSDK client = UnivecSDK.testSDK(testopts, sdkopts);
```

Creates a test-mode client with mock transport. Both arguments may be `null`.

### UnivecSDK methods

| Method | Signature | Description |
| --- | --- | --- |
| `optionsMap` | `() -> Map` | Deep copy of current SDK options. |
| `getUtility` | `() -> Utility` | Copy of the SDK utility object. |
| `prepare` | `(fetchargs) -> Map` | Build an HTTP request definition without sending. Raises on error. |
| `direct` | `(fetchargs) -> Map` | Build and send an HTTP request. Returns a result map (branch on `ok`). |
| `convert` | `(entopts) -> SdkEntity` | Create a Convert entity instance. |
| `embed` | `(entopts) -> SdkEntity` | Create an Embed entity instance. |
| `ephemeralKey` | `(entopts) -> SdkEntity` | Create an EphemeralKey entity instance. |
| `model` | `(entopts) -> SdkEntity` | Create a Model entity instance. |

### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
| `list` | `(reqmatch, ctrl) -> Object` | List entities matching the criteria (an aggregate list). Raises on error. |
| `create` | `(reqdata, ctrl) -> Object` | Create a new entity. Raises on error. |
| `data` | `(newdata...) -> Object` | Get or set entity data. |
| `match` | `(newmatch...) -> Object` | Get or set entity match criteria. |
| `make` | `() -> Entity` | Create a new instance with the same options. |
| `getName` | `() -> String` | Return the entity name. |

### Result shape

Entity operations return the ENTITY (call data() for the record) (a `Map` for single-entity
ops, an aggregate `List` for `list`) as `Object` and raise on error. Wrap
calls in `try`/`catch` to handle failures.

The `direct()` escape hatch never raises — it returns a result
`Map<String, Object>` you branch on via `result.get("ok")`:

| Key | Type | Description |
| --- | --- | --- |
| `ok` | `Boolean` | `true` if the HTTP status is 2xx. |
| `status` | `int` | HTTP status code. |
| `headers` | `Map` | Response headers. |
| `data` | `Object` | Parsed JSON response body. |

On error, `ok` is `false` and `err` contains the error value.

### Entities

#### Convert

| Field | Description |
| --- | --- |
| `embeddings` | Translated vectors, in the target model's dimension. |
| `source_model` | Model space the supplied vectors are currently in. |
| `target_model` | Model space to translate into. |

Operations: create.

API path: `/v1/convert`

#### Embed

| Field | Description |
| --- | --- |
| `embeddings` | One vector per input text, in input order. |
| `model` | Model that produced the vectors. |
| `texts` | Texts to embed. |

Operations: create.

API path: `/v1/embed`

#### EphemeralKey

| Field | Description |
| --- | --- |
| `dailyLimit` | Calls permitted per day. |
| `dailyUsed` | Calls already used today. |
| `key` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | When the daily allowance resets. |

Operations: create.

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

Operations: list.

API path: `/v1/models`



## Entities


### Convert

Create an instance: `SdkEntity convert = client.convert(null);`

#### Operations

| Method | Description |
| --- | --- |
| `create(data, null)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `List<Object>` | Translated vectors, in the target model's dimension. |
| `source_model` | `String` | Model space the supplied vectors are currently in. |
| `target_model` | `String` | Model space to translate into. |

#### Example: Create

```java
Object convert = client.convert(null).create(Map.of(
    "embeddings", List.of(),  // List<Object>
    "source_model", "example_source_model",  // String
    "target_model", "example_target_model"  // String
), null);
```


### Embed

Create an instance: `SdkEntity embed = client.embed(null);`

#### Operations

| Method | Description |
| --- | --- |
| `create(data, null)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `embeddings` | `List<Object>` | One vector per input text, in input order. |
| `model` | `String` | Model that produced the vectors. |
| `texts` | `List<Object>` | Texts to embed. |

#### Example: Create

```java
Object embed = client.embed(null).create(Map.of(
    "embeddings", List.of(),  // List<Object>
    "model", "example_model",  // String
    "texts", List.of()  // List<Object>
), null);
```


### EphemeralKey

Create an instance: `SdkEntity ephemeralKey = client.ephemeralKey(null);`

#### Operations

| Method | Description |
| --- | --- |
| `create(data, null)` | Create a new entity with the given data. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `dailyLimit` | `Long` | Calls permitted per day. |
| `dailyUsed` | `Long` | Calls already used today. |
| `key` | `String` | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `String` | When the daily allowance resets. |

#### Example: Create

```java
Object ephemeralKey = client.ephemeralKey(null).create(Map.of(
    "dailyLimit", 1L,  // Long
    "dailyUsed", 1L,  // Long
    "key", "example_key",  // String
    "resetsAt", "example_resetsAt"  // String
), null);
```


### Model

Create an instance: `SdkEntity model = client.model(null);`

#### Operations

| Method | Description |
| --- | --- |
| `list(null, null)` | List entities, optionally matching the given criteria. |

#### Fields

| Field | Type | Description |
| --- | --- | --- |
| `eval` | `Map<String, Object>` | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `String` | Hardware backend, e.g. |
| `modelCard` | `Map<String, Object>` | Convert models only: training provenance and architecture detail. |
| `modelType` | `String` | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `String` | Model identifier used in requests. |
| `sequenceLen` | `Long` | Embed models only: maximum input sequence length. |
| `sourceDim` | `Long` | Convert models only: source vector dimension. |
| `sourceModel` | `String` | Convert models only: the source model space. |
| `targetDim` | `Long` | Dimension of the produced vectors. |
| `targetModel` | `String` | The model space produced. |

#### Example: List

```java
Object modelList = client.model(null).list(null, null);
```

## Features

This SDK ships 19 optional features. Each is **inactive until you
switch it on**, so an SDK you have not configured behaves exactly as if none of
them existed — no retries, no cache, no logging, no measurable overhead.

Activate a feature by name in the client options, alongside the options shown
above:

| Feature | What it does |
|---|---|
| [`audit`](#audit) | Structured audit trail of operations |
| [`cache`](#cache) | Response caching for safe read requests |
| [`clienttrack`](#clienttrack) | Client identity and per-request correlation headers |
| [`cost`](#cost) | Cost tracking and spend budget for API calls |
| [`debug`](#debug) | Request/response capture ring buffer for debugging |
| [`idempotency`](#idempotency) | Idempotency keys for safe retries of mutating operations |
| [`log`](#log) | Structured request and response logging |
| [`metrics`](#metrics) | Statistics capture: per-operation counters and latency |
| [`netsim`](#netsim) | Network behaviour simulation for offline testing (latency, failures, outages) |
| [`paging`](#paging) | Pagination signals for list operations |
| [`proxy`](#proxy) | Outbound HTTP(S) proxy routing |
| [`ratelimit`](#ratelimit) | Client-side rate limiting via a token bucket |
| [`rbac`](#rbac) | Client-side role/permission enforcement |
| [`retry`](#retry) | Automatic retry of transient failures with exponential backoff |
| [`secrets`](#secrets) | Secret access: resolve the API credential through a provider chain, and exchange a refresh token for short-lived access tokens |
| [`streaming`](#streaming) | Incremental streaming of list results via async iteration |
| [`telemetry`](#telemetry) | Distributed tracing spans with W3C trace-context propagation |
| [`test`](#test) | In-memory mock transport for testing without a live server |
| [`timeout`](#timeout) | Per-request timeout with transport abort |

> **Order matters for `cache`, `cost`, `netsim`, `proxy`, `ratelimit`, `retry`, `secrets`, `timeout`.** These wrap the
> transport, so each one wraps whatever is already installed: the order you
> activate them in IS the nesting order. Activating them as an ordered list
> rather than a map is what fixes that order.

### audit

Structured audit trail of operations.

| Option | Default |
|---|---|
| `active` | `false` |
| `actor` | `'anonymous'` |
| `max` | `1000` |

Set `feature.audit.active` to enable it, then override any of the options above.

### cache

Response caching for safe read requests.

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `256` |
| `methods` | `['GET']` |
| `ttl` | `5000` |

Set `feature.cache.active` to enable it, then override any of the options above.

`cache` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### clienttrack

Client identity and per-request correlation headers.

| Option | Default |
|---|---|
| `active` | `false` |
| `clientVersion` | `'0.0.1'` |

Set `feature.clienttrack.active` to enable it, then override any of the options above.

### cost

Cost tracking and spend budget for API calls.

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

Set `feature.cost.active` to enable it, then override any of the options above.

`cost` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### debug

Request/response capture ring buffer for debugging.

| Option | Default |
|---|---|
| `active` | `false` |
| `max` | `100` |
| `redact` | `['authorization', 'cookie', 'set-cookie', 'api-key', 'apikey', 'x-api-key', 'idempotency-key']` |

Set `feature.debug.active` to enable it, then override any of the options above.

### idempotency

Idempotency keys for safe retries of mutating operations.

| Option | Default |
|---|---|
| `active` | `false` |
| `header` | `'Idempotency-Key'` |
| `methods` | `['POST', 'PUT', 'PATCH', 'DELETE']` |
| `ops` | `['create', 'update', 'remove']` |

Set `feature.idempotency.active` to enable it, then override any of the options above.

### log

Structured request and response logging.

| Option | Default |
|---|---|
| `active` | `true` |

Set `feature.log.active` to enable it, then override any of the options above.

### metrics

Statistics capture: per-operation counters and latency.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.metrics.active` to enable it, then override any of the options above.

### netsim

Network behaviour simulation for offline testing (latency, failures, outages).

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

Set `feature.netsim.active` to enable it, then override any of the options above.

`netsim` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### paging

Pagination signals for list operations.

| Option | Default |
|---|---|
| `active` | `false` |
| `afterVar` | `'after'` |
| `cursorParam` | `'cursor'` |
| `firstVar` | `'first'` |
| `limitParam` | `'limit'` |
| `pageParam` | `'page'` |
| `startPage` | `1` |

Set `feature.paging.active` to enable it, then override any of the options above.

### proxy

Outbound HTTP(S) proxy routing.

| Option | Default |
|---|---|
| `active` | `false` |
| `fromEnv` | `false` |
| `noProxy` | `[]` |
| `url` | `''` |

Set `feature.proxy.active` to enable it, then override any of the options above.

`proxy` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### ratelimit

Client-side rate limiting via a token bucket.

| Option | Default |
|---|---|
| `active` | `false` |
| `burst` | `5` |
| `rate` | `5` |

Set `feature.ratelimit.active` to enable it, then override any of the options above.

`ratelimit` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### rbac

Client-side role/permission enforcement.

| Option | Default |
|---|---|
| `active` | `false` |
| `deny` | `false` |
| `permissions` | `[]` |
| `rules` | `{}` |

Set `feature.rbac.active` to enable it, then override any of the options above.

### retry

Automatic retry of transient failures with exponential backoff.

| Option | Default |
|---|---|
| `active` | `false` |
| `factor` | `2` |
| `maxDelay` | `2000` |
| `minDelay` | `50` |
| `retries` | `2` |
| `statuses` | `[408, 425, 429, 500, 502, 503, 504]` |

Set `feature.retry.active` to enable it, then override any of the options above.

`retry` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### secrets

Secret access: resolve the API credential through a provider chain, and exchange a refresh token for short-lived access tokens.

| Option | Default |
|---|---|
| `active` | `false` |
| `cache` | `true` |
| `exchange` | `{active: false, method: 'POST', path: 'auth/token', refresh: '', request: 'refresh_token', response: 'access_token', retries: 1, statuses: [401]}` |
| `name` | `'univec'` |
| `providers` | `[{kind: 'boru', namespace: 'sdk'}]` |

Set `feature.secrets.active` to enable it, then override any of the options above.

`secrets` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.

### streaming

Incremental streaming of list results via async iteration.

| Option | Default |
|---|---|
| `active` | `false` |
| `chunkDelay` | `0` |
| `chunkSize` | `0` |

Set `feature.streaming.active` to enable it, then override any of the options above.

### telemetry

Distributed tracing spans with W3C trace-context propagation.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.telemetry.active` to enable it, then override any of the options above.

### test

In-memory mock transport for testing without a live server.

| Option | Default |
|---|---|
| `active` | `false` |

Set `feature.test.active` to enable it, then override any of the options above.

### timeout

Per-request timeout with transport abort.

| Option | Default |
|---|---|
| `active` | `false` |
| `ms` | `30000` |

Set `feature.timeout.active` to enable it, then override any of the options above.

`timeout` wraps the transport, so its position among the other
transport features decides what it sees. A feature activated later wraps one
activated earlier.


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

- **AuditFeature**: Structured audit trail of operations
- **CacheFeature**: Response caching for safe read requests
- **ClienttrackFeature**: Client identity and per-request correlation headers
- **CostFeature**: Cost tracking and spend budget for API calls
- **DebugFeature**: Request/response capture ring buffer for debugging
- **IdempotencyFeature**: Idempotency keys for safe retries of mutating operations
- **LogFeature**: Structured request and response logging
- **MetricsFeature**: Statistics capture: per-operation counters and latency
- **NetsimFeature**: Network behaviour simulation for offline testing (latency, failures, outages)
- **PagingFeature**: Pagination signals for list operations
- **ProxyFeature**: Outbound HTTP(S) proxy routing
- **RatelimitFeature**: Client-side rate limiting via a token bucket
- **RbacFeature**: Client-side role/permission enforcement
- **RetryFeature**: Automatic retry of transient failures with exponential backoff
- **SecretsFeature**: Secret access: resolve the API credential through a provider chain, and exchange a refresh token for short-lived access tokens
- **StreamingFeature**: Incremental streaming of list results via async iteration
- **TelemetryFeature**: Distributed tracing spans with W3C trace-context propagation
- **TestFeature**: In-memory mock transport for testing without a live server
- **TimeoutFeature**: Per-request timeout with transport abort

Features are initialized in order. Hooks fire in the order features
were added, so later features can override earlier ones.

### Data as maps

The Java SDK uses a loose object model — `Map<String, Object>` throughout —
rather than a bespoke typed class per endpoint. This mirrors the dynamic
nature of the API and keeps the SDK flexible: no regeneration is needed when
the API schema changes.

Use `Helpers.toMapAny(value)` to safely coerce a value to a
`Map<String, Object>`. A `UnivecTypes.java` module of reference
`record` types is also generated for editor documentation.

### Project structure

```
java/
├── pom.xml                     -- Maven project (compiles core/, utility/, feature/, entity/)
├── core/                       -- Main SDK client, config, entity base, error type
├── entity/                     -- Entity implementations
├── feature/                    -- Built-in features (Base, Test, Log, ...)
├── utility/                    -- Utility functions and the vendored struct library
└── test/                       -- JUnit test suites
```

The main client class (`UnivecSDK`, package `voxgig.univecsdk.core`)
exposes the entity accessors. Reference entity or utility types directly only
when needed.

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
