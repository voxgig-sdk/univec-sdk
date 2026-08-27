# Univec Zig SDK Reference

Complete API reference for the Univec Zig SDK.


## UnivecSDK

### Constructor

```zig
const sdk = @import("sdk");
const h = sdk.h;

const client = sdk.UnivecSDK.new(options);
```

Create a new SDK client instance. `options` is a `Value` map
(`h.vnull()` for none).

**Parameters:**

| Key | Value type | Description |
| --- | --- | --- |
| `apikey` | `string` | API key for authentication. |
| `base` | `string` | Base URL for API requests. |
| `prefix` | `string` | URL prefix appended after base. |
| `suffix` | `string` | URL suffix appended after path. |
| `headers` | `map` | Custom headers for all requests. |
| `feature` | `map` | Feature configuration. |
| `system` | `map` | System overrides. |


### Static Functions

#### `test_sdk(testopts: Value, sdkopts: Value) *UnivecSDK`

Create a test client with mock features active. Both arguments may be
`h.vnull()`.

```zig
const client = sdk.test_sdk(h.vnull(), h.vnull());
```


### Instance Methods

#### `convert(entopts: Value) *ConvertEntity`

Create a new `ConvertEntity` instance. Pass `h.vnull()` for no
initial options.

#### `embed(entopts: Value) *EmbedEntity`

Create a new `EmbedEntity` instance. Pass `h.vnull()` for no
initial options.

#### `ephemeral_key(entopts: Value) *EphemeralKeyEntity`

Create a new `EphemeralKeyEntity` instance. Pass `h.vnull()` for no
initial options.

#### `model(entopts: Value) *ModelEntity`

Create a new `ModelEntity` instance. Pass `h.vnull()` for no
initial options.

#### `options_map() Value`

Return a deep copy of the current SDK options.

#### `get_utility() *Utility`

Return a copy of the SDK utility object.

#### `direct(fetchargs: Value) Value`

Make a direct HTTP request to any API endpoint. Returns a result `Value`
map with `ok`, `status`, `headers`, and `data` (or `err` on failure).
This escape hatch returns a map even on a non-2xx response — branch on
`h.get_bool(result, "ok")`.

**Parameters (`fetchargs` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| `path` | `string` | URL path with optional `{param}` placeholders. |
| `method` | `string` | HTTP method (default: `"GET"`). |
| `params` | `map` | Path parameter values. |
| `query` | `map` | Query string parameters. |
| `headers` | `map` | Request headers (merged with defaults). |
| `body` | `any` | Request body (maps are JSON-serialized). |

#### `prepare(fetchargs: Value) E!Value`

Prepare a fetch definition without sending. Returns the fetchdef (use
`catch`/`try` to handle the error union).


---

## ConvertEntity

```zig
const convert = client.convert(h.vnull());
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `[]const u8` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `Value (array)` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `[]const u8` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `[]const u8` | Yes | Model space to translate into. |
| `texts` | `Value (array)` | Yes | Texts to embed and translate. |

### Operations

#### `create(reqdata: Value, ctrl: Value) OpResult`

Create a new entity with the given data. `.ok` carries the created entity data.

```zig
switch (client.convert(h.vnull()).create(h.jo(&.{
    .{ "bridge_model", h.vstr("example_bridge_model") }, // []const u8
    .{ "embeddings", h.olist() }, // Value (array)
    .{ "source_model", h.vstr("example_source_model") }, // []const u8
    .{ "target_model", h.vstr("example_target_model") }, // []const u8
    .{ "texts", h.olist() }, // Value (array)
}), h.vnull())) {
    .ok => |result| std.debug.print("{s}\n", .{h.stringify(result)}),
    .err => |e| std.debug.print("create failed: {s}\n", .{e.msg}),
}
```

### Common Methods

#### `data(args: ?Value) Value`

Get the entity data. Pass a map to set it.

#### `matchv(args: ?Value) Value`

Get the entity match criteria. Pass a map to set it.

#### `stream(action: []const u8, args: Value, callopts: Value) []Value`

Run an operation through the pipeline and materialise its result items.

#### `get_name() []const u8`

Return the entity name.


---

## EmbedEntity

```zig
const embed = client.embed(h.vnull());
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `Value (array)` | Yes | One vector per input text, in input order. |
| `model` | `[]const u8` | Yes | Model that produced the vectors. |
| `texts` | `Value (array)` | Yes | Texts to embed. |

### Operations

#### `create(reqdata: Value, ctrl: Value) OpResult`

Create a new entity with the given data. `.ok` carries the created entity data.

```zig
switch (client.embed(h.vnull()).create(h.jo(&.{
    .{ "embeddings", h.olist() }, // Value (array)
    .{ "model", h.vstr("example_model") }, // []const u8
    .{ "texts", h.olist() }, // Value (array)
}), h.vnull())) {
    .ok => |result| std.debug.print("{s}\n", .{h.stringify(result)}),
    .err => |e| std.debug.print("create failed: {s}\n", .{e.msg}),
}
```

### Common Methods

#### `data(args: ?Value) Value`

Get the entity data. Pass a map to set it.

#### `matchv(args: ?Value) Value`

Get the entity match criteria. Pass a map to set it.

#### `stream(action: []const u8, args: Value, callopts: Value) []Value`

Run an operation through the pipeline and materialise its result items.

#### `get_name() []const u8`

Return the entity name.


---

## EphemeralKeyEntity

```zig
const ephemeral_key = client.ephemeral_key(h.vnull());
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `i64` | Yes | Calls permitted per day. |
| `dailyUsed` | `i64` | Yes | Calls already used today. |
| `key` | `[]const u8` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `[]const u8` | Yes | When the daily allowance resets. |

### Operations

#### `create(reqdata: Value, ctrl: Value) OpResult`

Create a new entity with the given data. `.ok` carries the created entity data.

```zig
switch (client.ephemeral_key(h.vnull()).create(h.jo(&.{
    .{ "dailyLimit", h.vnum(1) }, // i64
    .{ "dailyUsed", h.vnum(1) }, // i64
    .{ "key", h.vstr("example_key") }, // []const u8
    .{ "resetsAt", h.vstr("example_resetsAt") }, // []const u8
}), h.vnull())) {
    .ok => |result| std.debug.print("{s}\n", .{h.stringify(result)}),
    .err => |e| std.debug.print("create failed: {s}\n", .{e.msg}),
}
```

### Common Methods

#### `data(args: ?Value) Value`

Get the entity data. Pass a map to set it.

#### `matchv(args: ?Value) Value`

Get the entity match criteria. Pass a map to set it.

#### `stream(action: []const u8, args: Value, callopts: Value) []Value`

Run an operation through the pipeline and materialise its result items.

#### `get_name() []const u8`

Return the entity name.


---

## ModelEntity

```zig
const model = client.model(h.vnull());
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `Value (object)` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `[]const u8` | No | Hardware backend, e.g. |
| `modelCard` | `Value (object)` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `[]const u8` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `[]const u8` | Yes | Model identifier used in requests. |
| `sequenceLen` | `i64` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `i64` | No | Convert models only: source vector dimension. |
| `sourceModel` | `[]const u8` | No | Convert models only: the source model space. |
| `targetDim` | `i64` | Yes | Dimension of the produced vectors. |
| `targetModel` | `[]const u8` | Yes | The model space produced. |

### Operations

#### `list(reqmatch: Value, ctrl: Value) OpResult`

List entities matching the given criteria. The match is optional — pass `h.vnull()` to list all records. `.ok` is a `Value` array.

```zig
switch (client.model(h.vnull()).list(h.vnull(), h.vnull())) {
    .ok => |results| std.debug.print("{s}\n", .{h.stringify(results)}),
    .err => |e| std.debug.print("list failed: {s}\n", .{e.msg}),
}
```

### Common Methods

#### `data(args: ?Value) Value`

Get the entity data. Pass a map to set it.

#### `matchv(args: ?Value) Value`

Get the entity match criteria. Pass a map to set it.

#### `stream(action: []const u8, args: Value, callopts: Value) []Value`

Run an operation through the pipeline and materialise its result items.

#### `get_name() []const u8`

Return the entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```zig
const client = sdk.UnivecSDK.new(h.jo(&.{
    .{ "feature", h.jo(&.{
        .{ "test", h.jo(&.{.{ "active", h.vbool(true) }}) },
    }) },
}));
```

