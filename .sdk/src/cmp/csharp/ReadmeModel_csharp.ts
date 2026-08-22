
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a
  // load/list/create/update/remove row only for operations at least one active
  // entity actually exposes — never document an operation no entity has.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `Load` | `(reqmatch, ctrl) -> object?` | Load a single entity by match criteria. Raises on error. |',
    list: '| `List` | `(reqmatch, ctrl) -> object?` | List entities matching the criteria (an aggregate list). Raises on error. |',
    create: '| `Create` | `(reqdata, ctrl) -> object?` | Create a new entity. Raises on error. |',
    update: '| `Update` | `(reqdata, ctrl) -> object?` | Update an existing entity. Raises on error. |',
    remove: '| `Remove` | `(reqmatch, ctrl) -> object?` | Remove an entity. Raises on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### ${model.const.Name}SDK

\`\`\`csharp
using ${model.const.Name}Sdk;

var client = new ${model.const.Name}SDK(options);
\`\`\`

Creates a new SDK client. \`options\` is a \`Dictionary<string, object?>\`.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`Dictionary\` | Feature activation flags. |
| \`extend\` | \`List\` | Additional Feature instances to load. |
| \`system\` | \`Dictionary\` | System overrides (e.g. custom \`fetch\` delegate). |

### TestSDK

\`\`\`csharp
var client = ${model.const.Name}SDK.TestSDK(testopts, sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`null\`.

### ${model.const.Name}SDK methods

| Method | Signature | Description |
| --- | --- | --- |
| \`OptionsMap\` | \`() -> Dictionary\` | Deep copy of current SDK options. |
| \`GetUtility\` | \`() -> Utility\` | Copy of the SDK utility object. |
| \`Prepare\` | \`(fetchargs) -> Dictionary\` | Build an HTTP request definition without sending. Raises on error. |
| \`Direct\` | \`(fetchargs) -> Dictionary\` | Build and send an HTTP request. Returns a result dictionary (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ent.Name}\` | \`(entopts) -> ${model.const.Name}EntityBase\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`Data\` | \`(newdata) -> object?\` | Get or set entity data. |
| \`Match\` | \`(newmatch) -> object?\` | Get or set entity match criteria. |
| \`Make\` | \`() -> IEntity\` | Create a new instance with the same options. |
| \`GetName\` | \`() -> string\` | Return the entity name. |

### Result shape

Entity operations return the bare result data (a \`Dictionary\` for
single-entity ops, an aggregate list for \`List\`) as \`object?\` and raise on
error. Wrap calls in \`try\`/\`catch\` to handle failures.

The \`Direct()\` escape hatch never raises — it returns a result
\`Dictionary<string, object?>\` you branch on via \`result["ok"]\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`bool\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`int\` | HTTP status code. |
| \`headers\` | \`Dictionary\` | Response headers. |
| \`data\` | \`object?\` | Parsed JSON response body. |

On error, \`ok\` is \`false\` and \`err\` contains the error value.

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
