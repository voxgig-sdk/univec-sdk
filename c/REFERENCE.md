# Univec C SDK Reference

Complete API reference for the Univec C SDK.


## UnivecSDK

### Constructor

```c
#include "core/api.h"

UnivecSDK* client = univec_sdk_new(options);
```

Create a new SDK client instance. `options` is a `voxgig_value*` map
(`NULL` for none).

**Parameters (`options` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| `apikey` | `string` | API key for authentication. |
| `base` | `string` | Base URL for API requests. |
| `prefix` | `string` | URL prefix appended after base. |
| `suffix` | `string` | URL suffix appended after path. |
| `headers` | `map` | Custom headers for all requests. |
| `feature` | `map` | Feature configuration. |
| `system` | `map` | System overrides. |


### Test Constructor

#### `UnivecSDK* test_sdk(voxgig_value* testopts, voxgig_value* sdkopts)`

Create a test client with mock features active. Both arguments may be
`NULL`.

```c
UnivecSDK* client = test_sdk(NULL, NULL);
```


### Entity Accessors

#### `Entity* univec_convert(UnivecSDK* client, voxgig_value* entopts)`

Create a new `Convert` entity instance. Pass `NULL` for no initial
options.

#### `Entity* univec_embed(UnivecSDK* client, voxgig_value* entopts)`

Create a new `Embed` entity instance. Pass `NULL` for no initial
options.

#### `Entity* univec_ephemeral_key(UnivecSDK* client, voxgig_value* entopts)`

Create a new `EphemeralKey` entity instance. Pass `NULL` for no initial
options.

#### `Entity* univec_model(UnivecSDK* client, voxgig_value* entopts)`

Create a new `Model` entity instance. Pass `NULL` for no initial
options.

#### `voxgig_value* sdk_direct(UnivecSDK* client, voxgig_value* fetchargs, PNError** err)`

Make a direct HTTP request to any API endpoint. Returns a result map with
`ok`, `status`, `headers`, and `data` (or `err` on failure). This escape
hatch never sets `*err` for a non-2xx response — branch on
`getp(result, "ok")`.

**Parameters (`fetchargs` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| `path` | `string` | URL path with optional `{param}` placeholders. |
| `method` | `string` | HTTP method (default: `"GET"`). |
| `params` | `map` | Path parameter values. |
| `query` | `map` | Query string parameters. |
| `headers` | `map` | Request headers (merged with defaults). |
| `body` | `any` | Request body (maps are JSON-serialized). |

#### `voxgig_value* sdk_prepare(UnivecSDK* client, voxgig_value* fetchargs, PNError** err)`

Prepare a fetch definition without sending. Returns the fetchdef and sets
`*err` on failure.


---

## Convert

```c
Entity* convert = univec_convert(client, NULL);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `char*` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `voxgig_value* (list)` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `char*` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `char*` | Yes | Model space to translate into. |
| `texts` | `voxgig_value* (list)` | Yes | Texts to embed and translate. |

### Operations

#### `vt->create(Entity* e, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err)`

Create a new entity with the given data. Returns the created entity data and sets `*err` on failure.

```c
Entity* convert = univec_convert(client, NULL);
voxgig_value* result = convert->vt->create(convert, cmap(5,
    "bridge_model", v_str("example_bridge_model"),  // char*
    "embeddings", v_list(),  // voxgig_value* (list)
    "source_model", v_str("example_source_model"),  // char*
    "target_model", v_str("example_target_model"),  // char*
    "texts", v_list())  // voxgig_value* (list)
, NULL, &err);
```

### Common Methods

#### `voxgig_value* vt->data(Entity* e, voxgig_value* args)`

Get the entity data. Pass a map to set it.

#### `voxgig_value* vt->matchv(Entity* e, voxgig_value* args)`

Get the entity match criteria. Pass a map to set it.

#### `Entity* vt->make(Entity* e)`

Create a new `Convert` entity instance with the same options.

#### `const char* vt->get_name(Entity* e)`

Return the entity name.


---

## Embed

```c
Entity* embed = univec_embed(client, NULL);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `voxgig_value* (list)` | Yes | One vector per input text, in input order. |
| `model` | `char*` | Yes | Model that produced the vectors. |
| `texts` | `voxgig_value* (list)` | Yes | Texts to embed. |

### Operations

#### `vt->create(Entity* e, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err)`

Create a new entity with the given data. Returns the created entity data and sets `*err` on failure.

```c
Entity* embed = univec_embed(client, NULL);
voxgig_value* result = embed->vt->create(embed, cmap(3,
    "embeddings", v_list(),  // voxgig_value* (list)
    "model", v_str("example_model"),  // char*
    "texts", v_list())  // voxgig_value* (list)
, NULL, &err);
```

### Common Methods

#### `voxgig_value* vt->data(Entity* e, voxgig_value* args)`

Get the entity data. Pass a map to set it.

#### `voxgig_value* vt->matchv(Entity* e, voxgig_value* args)`

Get the entity match criteria. Pass a map to set it.

#### `Entity* vt->make(Entity* e)`

Create a new `Embed` entity instance with the same options.

#### `const char* vt->get_name(Entity* e)`

Return the entity name.


---

## EphemeralKey

```c
Entity* ephemeral_key = univec_ephemeral_key(client, NULL);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `int64_t` | Yes | Calls permitted per day. |
| `dailyUsed` | `int64_t` | Yes | Calls already used today. |
| `key` | `char*` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `char*` | Yes | When the daily allowance resets. |

### Operations

#### `vt->create(Entity* e, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err)`

Create a new entity with the given data. Returns the created entity data and sets `*err` on failure.

```c
Entity* ephemeral_key = univec_ephemeral_key(client, NULL);
voxgig_value* result = ephemeral_key->vt->create(ephemeral_key, cmap(4,
    "dailyLimit", v_num(1),  // int64_t
    "dailyUsed", v_num(1),  // int64_t
    "key", v_str("example_key"),  // char*
    "resetsAt", v_str("example_resetsAt"))  // char*
, NULL, &err);
```

### Common Methods

#### `voxgig_value* vt->data(Entity* e, voxgig_value* args)`

Get the entity data. Pass a map to set it.

#### `voxgig_value* vt->matchv(Entity* e, voxgig_value* args)`

Get the entity match criteria. Pass a map to set it.

#### `Entity* vt->make(Entity* e)`

Create a new `EphemeralKey` entity instance with the same options.

#### `const char* vt->get_name(Entity* e)`

Return the entity name.


---

## Model

```c
Entity* model = univec_model(client, NULL);
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `voxgig_value* (map)` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `char*` | No | Hardware backend, e.g. |
| `modelCard` | `voxgig_value* (map)` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `char*` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `char*` | Yes | Model identifier used in requests. |
| `sequenceLen` | `int64_t` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `int64_t` | No | Convert models only: source vector dimension. |
| `sourceModel` | `char*` | No | Convert models only: the source model space. |
| `targetDim` | `int64_t` | Yes | Dimension of the produced vectors. |
| `targetModel` | `char*` | Yes | The model space produced. |

### Operations

#### `vt->list(Entity* e, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err)`

List entities matching the given criteria. The match is optional — pass `NULL` to list all records. Returns a List.

```c
Entity* model = univec_model(client, NULL);
voxgig_value* results = model->vt->list(model, NULL, NULL, &err);
for (size_t i = 0; i < (size_t)voxgig_size(results); i++) {
    printf("%s\n", voxgig_to_json(voxgig_getelem(results, v_int(i), NULL)));
}
```

### Common Methods

#### `voxgig_value* vt->data(Entity* e, voxgig_value* args)`

Get the entity data. Pass a map to set it.

#### `voxgig_value* vt->matchv(Entity* e, voxgig_value* args)`

Get the entity match criteria. Pass a map to set it.

#### `Entity* vt->make(Entity* e)`

Create a new `Model` entity instance with the same options.

#### `const char* vt->get_name(Entity* e)`

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

```c
UnivecSDK* client = univec_sdk_new(cmap(1,
    "feature", cmap(18,
        "audit", cmap(1, "active", v_bool(true)),
        "cache", cmap(1, "active", v_bool(true)),
        "clienttrack", cmap(1, "active", v_bool(true)),
        "cost", cmap(1, "active", v_bool(true)),
        "debug", cmap(1, "active", v_bool(true)),
        "idempotency", cmap(1, "active", v_bool(true)),
        "log", cmap(1, "active", v_bool(true)),
        "metrics", cmap(1, "active", v_bool(true)),
        "netsim", cmap(1, "active", v_bool(true)),
        "paging", cmap(1, "active", v_bool(true)),
        "proxy", cmap(1, "active", v_bool(true)),
        "ratelimit", cmap(1, "active", v_bool(true)),
        "rbac", cmap(1, "active", v_bool(true)),
        "retry", cmap(1, "active", v_bool(true)),
        "streaming", cmap(1, "active", v_bool(true)),
        "telemetry", cmap(1, "active", v_bool(true)),
        "test", cmap(1, "active", v_bool(true)),
        "timeout", cmap(1, "active", v_bool(true)))
));
```

