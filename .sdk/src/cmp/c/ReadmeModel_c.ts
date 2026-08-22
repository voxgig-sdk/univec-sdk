
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cIdent, cVarName } from './utility_c'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const ident = cIdent(model)
  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity vtable: emit a row only for
  // operations at least one active entity actually exposes.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(Entity*, reqmatch, ctrl, PNError**) -> voxgig_value*` | Load a single entity by match criteria. |',
    list: '| `list` | `(Entity*, reqmatch, ctrl, PNError**) -> voxgig_value*` | List entities matching the criteria (a List). |',
    create: '| `create` | `(Entity*, reqdata, ctrl, PNError**) -> voxgig_value*` | Create a new entity. |',
    update: '| `update` | `(Entity*, reqdata, ctrl, PNError**) -> voxgig_value*` | Update an existing entity. |',
    remove: '| `remove` | `(Entity*, reqmatch, ctrl, PNError**) -> voxgig_value*` | Remove an entity. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### ${Name}SDK

\`\`\`c
#include "core/api.h"

${Name}SDK* client = ${ident}_sdk_new(options);
\`\`\`

Creates a new SDK client. \`options\` is a \`voxgig_value*\` map (\`NULL\` for
none) carrying any of the following keys:

| Option | Value type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`map\` | Feature activation flags. |
| \`system\` | \`map\` | System overrides (e.g. a custom \`fetch\`). |

### test_sdk

\`\`\`c
${Name}SDK* client = test_sdk(testopts, sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be
\`NULL\`.

### ${Name}SDK functions

| Function | Signature | Description |
| --- | --- | --- |
| \`sdk_prepare\` | \`(${Name}SDK*, fetchargs, PNError**) -> voxgig_value*\` | Build an HTTP request definition without sending. |
| \`sdk_direct\` | \`(${Name}SDK*, fetchargs, PNError**) -> voxgig_value*\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ident}_${cVarName(ent.name)}\` | \`(${Name}SDK*, entopts) -> Entity*\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface (vtable)

All entities share the same \`EntityVT\` vtable, reached via \`e->vt->...\`.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data\` | \`(Entity*, args) -> voxgig_value*\` | Get entity data (pass a map to set). |
| \`matchv\` | \`(Entity*, args) -> voxgig_value*\` | Get entity match criteria (pass a map to set). |
| \`make\` | \`(Entity*) -> Entity*\` | Create a new instance with the same options. |
| \`get_name\` | \`(Entity*) -> const char*\` | Return the entity name. |

### Result shape

Entity operations return the bare result data (a \`voxgig_value\` map for
single-entity ops, a List for \`list\`) and set \`*err\` to a \`PNError*\` on
failure. Always initialise \`PNError* err = NULL;\` and check it after the
call.

The \`sdk_direct()\` escape hatch never sets \`*err\` for a non-2xx response —
it returns a result map you branch on via \`getp(result, "ok")\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`bool\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`number\` | HTTP status code. |
| \`headers\` | \`map\` | Response headers. |
| \`data\` | \`any\` | Parsed JSON response body. |

On error, \`ok\` is \`false\` and \`err\` carries the error value.

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
