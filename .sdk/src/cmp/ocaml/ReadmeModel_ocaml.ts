
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


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
    load: '| `e_load` | `value -> value -> entity_obj` | Load a single entity by match criteria. Resolves to the entity. Raises on error. |',
    list: '| `e_list` | `value -> value -> entity_obj list` | List entities matching the criteria. Resolves to one entity per record. Raises on error. |',
    create: '| `e_create` | `value -> value -> entity_obj` | Create a new entity. Resolves to the entity. Raises on error. |',
    update: '| `e_update` | `value -> value -> entity_obj` | Update an existing entity. Resolves to the entity. Raises on error. |',
    remove: '| `e_remove` | `value -> value -> entity_obj` | Remove an entity. Resolves to the entity, marked deleted. Raises on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### Sdk_client

\`\`\`ocaml
open Voxgig_struct
open Sdk_helpers

let client = Sdk_client.make options
\`\`\`

Creates a new SDK client from a \`value\` options map. Use \`Sdk_client.make0 ()\`
for defaults.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`map\` | Feature activation flags. |
| \`extend\` | \`list\` | Additional feature instances to load. |
| \`system\` | \`map\` | System overrides (e.g. custom \`fetch\` function). |

### Sdk_client.test

\`\`\`ocaml
let client = Sdk_client.test_with testopts sdkopts
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`Noval\`
(\`Sdk_client.test ()\` uses defaults).

### Sdk_client functions

| Function | Signature | Description |
| --- | --- | --- |
| \`make\` | \`value -> sdk_client\` | Construct a client from options. |
| \`make0\` | \`unit -> sdk_client\` | Construct a client with defaults. |
| \`prepare\` | \`sdk_client -> value -> value\` | Build an HTTP request definition without sending. Raises on error. |
| \`direct\` | \`sdk_client -> value -> value\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const fn = ocamlVarName(ent.name)
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${fn}\` | \`sdk_client -> value -> entity_obj\` | ${article.charAt(0).toUpperCase() + article.slice(1)} ${ent.Name} entity accessor. |
`)
  })

  Content(`
### Entity interface

All entities are \`entity_obj\` records sharing the same fields.

| Field | Signature | Description |
| --- | --- | --- |
${opRows}
| \`e_data_get\` | \`unit -> value\` | Get entity data. |
| \`e_data_set\` | \`value -> unit\` | Set entity data. |
| \`e_match_get\` | \`unit -> value\` | Get entity match criteria. |
| \`e_match_set\` | \`value -> unit\` | Set entity match criteria. |
| \`e_make\` | \`unit -> entity_obj\` | Create a new instance with the same options. |
| \`e_name\` | \`string\` | The entity name. |

### Result shape

Entity operations resolve to the ENTITY, not the raw record \u2014 \`e_list\` to
one entity per record \u2014 and raise \`Sdk_error.E\` on error. The record is
reached through \`e_data_get\`, which returns the entity's data container.
\`e_remove\` resolves to the entity marked deleted (\`e_deleted\`); it keeps the
data it held. Wrap calls in \`try\`/\`with\` to handle failures.

The \`direct\` escape hatch never raises — it returns a result \`value\` map
you branch on via \`getp result "ok"\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`Bool\` | \`Bool true\` if the HTTP status is 2xx. |
| \`status\` | \`Num\` | HTTP status code. |
| \`headers\` | \`Map\` | Response headers. |
| \`data\` | \`value\` | Parsed JSON response body. |

On error, \`ok\` is \`Bool false\` and \`err\` carries the error value.

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
