
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { zigVarName } from './utility_zig'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a row only for
  // operations at least one active entity actually exposes.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(reqmatch: Value, ctrl: Value) OpResult` | Load a single entity by match criteria. |',
    list: '| `list` | `(reqmatch: Value, ctrl: Value) OpResult` | List entities matching the criteria (`.ok` is a `Value` array). |',
    create: '| `create` | `(reqdata: Value, ctrl: Value) OpResult` | Create a new entity. |',
    update: '| `update` | `(reqdata: Value, ctrl: Value) OpResult` | Update an existing entity. |',
    remove: '| `remove` | `(reqmatch: Value, ctrl: Value) OpResult` | Remove an entity. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### ${model.const.Name}SDK

\`\`\`zig
const sdk = @import("sdk");
const h = sdk.h;

const client = sdk.${model.const.Name}SDK.new(options);
\`\`\`

Creates a new SDK client. \`options\` is a \`Value\` map (\`h.vnull()\` for
none) carrying any of the following keys:

| Option | Value type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`map\` | Feature activation flags. |
| \`system\` | \`map\` | System overrides (e.g. a custom fetcher). |

### test_sdk

\`\`\`zig
const client = sdk.test_sdk(testopts, sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be
\`h.vnull()\`.

### ${model.const.Name}SDK methods

| Method | Signature | Description |
| --- | --- | --- |
| \`options_map\` | \`() Value\` | Deep copy of the current SDK options. |
| \`get_utility\` | \`() *Utility\` | Copy of the SDK utility object. |
| \`prepare\` | \`(fetchargs: Value) E!Value\` | Build an HTTP request definition without sending. |
| \`direct\` | \`(fetchargs: Value) Value\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${zigVarName(ent.name)}\` | \`(entopts: Value) *${ent.Name}Entity\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`stream\` | \`(action: []const u8, args: Value, callopts: Value) []Value\` | Run an op through the pipeline and materialise its result items. |
| \`data\` | \`(args: ?Value) Value\` | Get entity data (pass a map to set). |
| \`matchv\` | \`(args: ?Value) Value\` | Get entity match criteria (pass a map to set). |
| \`get_name\` | \`() []const u8\` | Return the entity name. |

### Result shape

Entity operations return an \`OpResult\` union — \`switch\` on it: \`.ok\`
carries the bare result data (a \`Value\` object for single-entity ops, a
\`Value\` array for \`list\`), \`.err\` carries the branded error pointer.

The \`direct()\` escape hatch returns a result \`Value\` map directly (no
error union) — even on a non-2xx response — that you branch on via
\`h.get_bool(result, "ok")\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`bool\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`number\` | HTTP status code. |
| \`headers\` | \`map\` | Response headers. |
| \`data\` | \`any\` | Parsed JSON response body. |

On error, \`ok\` is \`false\` and \`err\` carries the error message.

`)

  // Entities summary
  Content(`### Entities

`)
  each(entityList, (ent: any) => {
    const fields = ent.fields || []
    const opnames = Object.keys(ent.op || {})
    const ops = ent.op || {}
    const points = each(ops).map((op: any) =>
      op.points ? each(op.points) : []
    ).flat()
    const path = points.length > 0 ? (points[0] as any).orig || '' : ''

    Content(`#### ${ent.Name}

| Field | Description |
| --- | --- |
`)
    each(fields, (field: any) => {
      Content(`| \`${field.name}\` | ${field.short || ''} |
`)
    })

    Content(`
Operations: ${opnames.map((n: string) => n.charAt(0).toUpperCase() + n.slice(1)).join(', ')}.

API path: \`${path}\`

`)
  })

})


export {
  ReadmeModel
}
