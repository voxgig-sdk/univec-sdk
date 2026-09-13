# Univec Lean SDK



The Lean SDK for the Univec API — an entity-oriented client
for Lean 4. The API is surfaced as capitalised Entities with a small, uniform
verb set (`list`, `load`, `create`, `update`, `remove`); every operation is
driven by the embedded config through the dependency-free vendored voxgig
`Value` struct model, and runs in struct's `SIO` monad.


## Install
This package is not yet published to [Reservoir](https://reservoir.lean-lang.org).
Install it from the GitHub release tag (`lean/vX.Y.Z`, see
[Releases](https://github.com/voxgig-sdk/univec-sdk/releases)) or from a source checkout. The runtime is
dependency-free (only the Lean 4 prelude + Std; the HTTP transport shells out
to `curl`), so a plain Lake build is all that is needed:

```bash
cd lean && lake build
```

Run the offline struct-corpus test (no server needed) and the live entity
tests (point them at a server with `SDK_TEST_BASE`):

```bash
lake exe omnismoke
lake exe structcorpus
SDK_TEST_BASE=http://localhost:8901 lake exe runner
```


## Tutorial: your first API call

This tutorial walks through creating a client, listing entities, and
loading a specific record.

Construct a client with `Sdk.newSdk` and call an entity op. Everything runs
in struct's `SIO` monad, so wrap your calls and `.run` them on a fresh `mkCtx`:

```lean
import SdkClient

open VoxgigStruct

def main : IO Unit := do
  let ctx ← mkCtx
  (do
    let opts ← newMap #[("base", .str "https://api.example.com"), ("apikey", .str (← IO.getEnv "UNIVEC").getD "")]
    let sdk ← Sdk.newSdk opts
    let result ← Convert.create sdk (← emptyMap) (← emptyMap)
    IO.println s!"result: {← stringify result}"
  ).run ctx
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

**Handle a missing record.** A `load` that finds nothing yields a
non-map value, so match on it:

```lean
match (← Entity.load sdk m (← emptyMap)) with
| .map _ => IO.println "found"
| _ => IO.println "not found"
```

**Test without a server.** `Sdk.testSdk0` takes seed data (the shape of the
generated `<Entity>TestData.json`) and answers operations from an in-memory
store, so entity behaviour can be exercised offline:

```lean
let seed ← SdkJson.jsonRead (← IO.FS.readFile "../.sdk/test/entity/<e>/<E>TestData.json")
let sdk ← Sdk.testSdk0 seed
```


## Reference

Every value crossing the SDK boundary — options, request payloads,
responses and results — is a vendored voxgig `Value` (see `VoxgigStruct.lean`):
a JSON-shaped, heap-backed node, the Lean equivalent of the `map[string]any`
the Go and Python SDKs pass around. Operations run in struct's `SIO` monad
(`ReaderT Ctx IO`), so a single `mkCtx` is threaded through a run:

```lean
let ctx ← mkCtx
(do
  let sdk ← Sdk.newSdk (← emptyMap)
  ...
).run ctx
```

Build values with `newMap` / `newList`, read them with `getprop` / `getpath`,
and render them with `stringify` (debug) or `jsonify` (strict JSON).

Options are a struct `Value` map passed to `Sdk.newSdk`:

| Option | Meaning |
| --- | --- |
| `base` | API base URL (overrides the built-in default) |
| `prefix` / `suffix` | Path fragments wrapped around every request path |
| `headers` | Default request headers (merged with per-request headers) |
| `apikey` | Bearer/api key, sent via the `authorization` header |
| `entity` | Per-entity option overrides, keyed by entity name |

```lean
let opts ← newMap #[("base", .str "https://api.example.com"), ("apikey", .str key)]
let sdk ← Sdk.newSdk opts
```

## Features

This SDK ships 18 optional features. Each is **inactive until you
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
| [`streaming`](#streaming) | Incremental streaming of list results via async iteration |
| [`telemetry`](#telemetry) | Distributed tracing spans with W3C trace-context propagation |
| [`test`](#test) | In-memory mock transport for testing without a live server |
| [`timeout`](#timeout) | Per-request timeout with transport abort |

> **`cache`, `cost`, `netsim`, `proxy`, `ratelimit`, `retry`, `timeout` wrap the transport**, so each one wraps
> whatever is already installed. This SDK composes them in a fixed catalog
> order, not the order you activate them in, and takes `feature` as a map.

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
- **StreamingFeature**: Incremental streaming of list results via async iteration
- **TelemetryFeature**: Distributed tracing spans with W3C trace-context propagation
- **TestFeature**: In-memory mock transport for testing without a live server
- **TimeoutFeature**: Per-request timeout with transport abort

Features are initialized in order. Hooks fire in the order features
were added, so later features can override earlier ones.

The SDK is **config-driven**: the API model is embedded as JSON in
`SdkConfig.lean` and parsed into a `Value` when a client is constructed. An
operation looks up its entity and op in that model, selects the matching
endpoint (a point whose `select.exist` keys are satisfied), builds the URL from
the point's path parts, applies the request transform, performs the call, then
applies the response transform. Because the pipeline is data-driven rather than
generated per entity, every entity and every API follow exactly the same path.

The HTTP transport shells out to `curl` via `IO.Process` — Lean 4 has no HTTP
library in its standard distribution, and this keeps the package free of Lake
dependencies.

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
