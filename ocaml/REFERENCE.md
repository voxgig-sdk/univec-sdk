# Univec OCaml SDK Reference

Complete API reference for the Univec OCaml SDK.


## Sdk_client

### Constructor

```ocaml
open Voxgig_struct
open Sdk_helpers

let client = Sdk_client.make options
```

Create a new SDK client instance from a `value` options map. Use
`Sdk_client.make0 ()` for defaults.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `value` | SDK configuration options (a Map). |
| `apikey` | `string` | API key for authentication. |
| `base` | `string` | Base URL for API requests. |
| `prefix` | `string` | URL prefix appended after base. |
| `suffix` | `string` | URL suffix appended after path. |
| `headers` | `map` | Custom headers for all requests. |
| `feature` | `map` | Feature configuration. |
| `system` | `map` | System overrides (e.g. custom fetch). |


### Static constructors

#### `Sdk_client.test testopts sdkopts`

Create a test client with mock features active. Both arguments may be `Noval`
(`Sdk_client.test ()` uses defaults, `Sdk_client.test_with` takes explicit
options).

```ocaml
let client = Sdk_client.test ()
```


### Instance functions

#### `Sdk_client.convert client entopts : entity_obj`

Create a `Convert` entity accessor. Pass `Noval` for no initial options.

#### `Sdk_client.embed client entopts : entity_obj`

Create a `Embed` entity accessor. Pass `Noval` for no initial options.

#### `Sdk_client.ephemeral_key client entopts : entity_obj`

Create a `EphemeralKey` entity accessor. Pass `Noval` for no initial options.

#### `Sdk_client.model client entopts : entity_obj`

Create a `Model` entity accessor. Pass `Noval` for no initial options.

#### `Sdk_client.direct client fetchargs : value`

Make a direct HTTP request to any API endpoint. Returns a result `value` map
with `ok`, `status`, `headers`, and `data` (or `err` on failure). This
escape hatch never raises — branch on `getp result "ok"`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| `path` | `string` | URL path with optional `{param}` placeholders. |
| `method` | `string` | HTTP method (default: `"GET"`). |
| `params` | `map` | Path parameter values. |
| `query` | `map` | Query string parameters. |
| `headers` | `map` | Request headers (merged with defaults). |
| `body` | `value` | Request body (Maps are JSON-serialized). |

**Returns:** a result `value` map.

#### `Sdk_client.prepare client fetchargs : value`

Prepare a fetch definition without sending. Returns the `fetchdef` and raises
on error.


---

## Convert

```ocaml
let convert = Sdk_client.convert client Noval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bridge_model` | `string` | Yes | Embed model used to vectorise the text before translation. |
| `embeddings` | `value list` | Yes | Translated vectors, in the target model's dimension. |
| `source_model` | `string` | Yes | Model space the supplied vectors are currently in. |
| `target_model` | `string` | Yes | Model space to translate into. |
| `texts` | `value list` | Yes | Texts to embed and translate. |

### Operations

#### `e_create reqdata ctrl : entity_obj`

Create a new entity with the given data. Resolves to the ENTITY (read the record with `e_data_get`) and raises on error.

```ocaml
let result = (Sdk_client.convert client Noval).e_create (jo [
    ("bridge_model", (Str "example_bridge_model"));  (* string *)
    ("embeddings", (empty_list ()));  (* value list *)
    ("source_model", (Str "example_source_model"));  (* string *)
    ("target_model", (Str "example_target_model"));  (* string *)
    ("texts", (empty_list ()));  (* value list *)
]) Noval
let result_data = result.e_data_get ()
```

### Common Fields

#### `e_data_get : unit -> value`

Get the entity data.

#### `e_data_set : value -> unit`

Set the entity data.

#### `e_match_get : unit -> value`

Get the entity match criteria.

#### `e_match_set : value -> unit`

Set the entity match criteria.

#### `e_make : unit -> entity_obj`

Create a new `Convert` entity accessor with the same options.

#### `e_name : string`

The entity name.


---

## Embed

```ocaml
let embed = Sdk_client.embed client Noval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `embeddings` | `value list` | Yes | One vector per input text, in input order. |
| `model` | `string` | Yes | Model that produced the vectors. |
| `texts` | `value list` | Yes | Texts to embed. |

### Operations

#### `e_create reqdata ctrl : entity_obj`

Create a new entity with the given data. Resolves to the ENTITY (read the record with `e_data_get`) and raises on error.

```ocaml
let result = (Sdk_client.embed client Noval).e_create (jo [
    ("embeddings", (empty_list ()));  (* value list *)
    ("model", (Str "example_model"));  (* string *)
    ("texts", (empty_list ()));  (* value list *)
]) Noval
let result_data = result.e_data_get ()
```

### Common Fields

#### `e_data_get : unit -> value`

Get the entity data.

#### `e_data_set : value -> unit`

Set the entity data.

#### `e_match_get : unit -> value`

Get the entity match criteria.

#### `e_match_set : value -> unit`

Set the entity match criteria.

#### `e_make : unit -> entity_obj`

Create a new `Embed` entity accessor with the same options.

#### `e_name : string`

The entity name.


---

## EphemeralKey

```ocaml
let ephemeral_key = Sdk_client.ephemeral_key client Noval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `dailyLimit` | `int` | Yes | Calls permitted per day. |
| `dailyUsed` | `int` | Yes | Calls already used today. |
| `key` | `string` | Yes | The ephemeral API key, prefixed `eph_`. |
| `resetsAt` | `string` | Yes | When the daily allowance resets. |

### Operations

#### `e_create reqdata ctrl : entity_obj`

Create a new entity with the given data. Resolves to the ENTITY (read the record with `e_data_get`) and raises on error.

```ocaml
let result = (Sdk_client.ephemeral_key client Noval).e_create (jo [
    ("dailyLimit", (Num 1.));  (* int *)
    ("dailyUsed", (Num 1.));  (* int *)
    ("key", (Str "example_key"));  (* string *)
    ("resetsAt", (Str "example_resetsAt"));  (* string *)
]) Noval
let result_data = result.e_data_get ()
```

### Common Fields

#### `e_data_get : unit -> value`

Get the entity data.

#### `e_data_set : value -> unit`

Set the entity data.

#### `e_match_get : unit -> value`

Get the entity match criteria.

#### `e_match_set : value -> unit`

Set the entity match criteria.

#### `e_make : unit -> entity_obj`

Create a new `EphemeralKey` entity accessor with the same options.

#### `e_name : string`

The entity name.


---

## Model

```ocaml
let model = Sdk_client.model client Noval
```

### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eval` | `value map` | No | Retrieval-fidelity metrics for a convert model. |
| `executionProvider` | `string` | No | Hardware backend, e.g. |
| `modelCard` | `value map` | No | Convert models only: training provenance and architecture detail. |
| `modelType` | `string` | Yes | `embed` for text-to-vector models, `convert` for space-translation models. |
| `name` | `string` | Yes | Model identifier used in requests. |
| `sequenceLen` | `int` | No | Embed models only: maximum input sequence length. |
| `sourceDim` | `int` | No | Convert models only: source vector dimension. |
| `sourceModel` | `string` | No | Convert models only: the source model space. |
| `targetDim` | `int` | Yes | Dimension of the produced vectors. |
| `targetModel` | `string` | Yes | The model space produced. |

### Operations

#### `e_list reqmatch ctrl : entity_obj list`

List entities matching the given criteria. The match is optional — pass `(empty_map ())` to list all records. Resolves to one ENTITY per record and raises on error.

```ocaml
(* One ENTITY per record; the record is reached with e_data_get. *)
let results = (Sdk_client.model client Noval).e_list (empty_map ()) Noval in
List.iter (fun e -> print_endline (stringify (e.e_data_get ()))) results
```

### Common Fields

#### `e_data_get : unit -> value`

Get the entity data.

#### `e_data_set : value -> unit`

Set the entity data.

#### `e_match_get : unit -> value`

Get the entity match criteria.

#### `e_match_set : value -> unit`

Set the entity match criteria.

#### `e_make : unit -> entity_obj`

Create a new `Model` entity accessor with the same options.

#### `e_name : string`

The entity name.


---

## Features

| Feature | Version | Description |
| --- | --- | --- |
| `test` | 0.0.1 | In-memory mock transport for testing without a live server |


Features are activated via the `feature` option:

```ocaml
let client = Sdk_client.make (jo [
    ("feature", jo [
        ("test", jo [("active", Bool true)]);
    ]);
])
```

