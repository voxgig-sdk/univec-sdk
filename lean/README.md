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
