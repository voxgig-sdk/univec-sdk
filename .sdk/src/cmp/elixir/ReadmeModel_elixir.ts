
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { ctx$: { model } } = props

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a
  // load/list/create/update/remove row only for operations at least one active
  // entity actually exposes.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(entity, reqmatch, ctrl \\\\ nil) :: map()` | Load a single entity by match criteria. Raises on error. |',
    list: '| `list` | `(entity, reqmatch \\\\ nil, ctrl \\\\ nil) :: list()` | List entities matching the criteria. Raises on error. |',
    create: '| `create` | `(entity, reqdata, ctrl \\\\ nil) :: map()` | Create a new entity. Raises on error. |',
    update: '| `update` | `(entity, reqdata, ctrl \\\\ nil) :: map()` | Update an existing entity. Raises on error. |',
    remove: '| `remove` | `(entity, reqmatch \\\\ nil, ctrl \\\\ nil) :: map()` | Remove an entity. Raises on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `String.t()` | API key for authentication. |\n'
    : ''

  Content(`### ${Name}

\`\`\`elixir
sdk = ${Name}.new(options)
\`\`\`

Creates a new SDK client. \`options\` is a struct value node — build one from a
native map with \`${Name}.Helpers.deep/1\`.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`String.t()\` | Base URL of the API server. |
| \`prefix\` | \`String.t()\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`String.t()\` | URL path suffix appended to all requests. |
| \`feature\` | \`map()\` | Feature activation flags. |
| \`extend\` | \`list()\` | Additional feature instances to load. |
| \`system\` | \`map()\` | System overrides (e.g. custom \`fetch\` function). |

### test

\`\`\`elixir
sdk = ${Name}.test(testopts, sdkopts)
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`nil\`.

### ${Name} functions

| Function | Signature | Description |
| --- | --- | --- |
| \`options_map\` | \`(client) :: map()\` | Deep copy of current SDK options. |
| \`get_utility\` | \`(client) :: map()\` | The SDK utility node. |
| \`prepare\` | \`(client, fetchargs) :: map()\` | Build an HTTP request definition without sending. Raises on error. |
| \`direct\` | \`(client, fetchargs) :: map()\` | Build and send an HTTP request. Returns a result node (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ent.name}\` | \`(client, entopts \\\\ nil) :: entity\` | Create ${article} ${ent.Name} entity handle. |
`)
  })

  Content(`
### Entity interface

Every entity's \`${Name}.Entity.<Name>\` module shares the same interface.

| Function | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data_get\` | \`(entity) :: map()\` | Get entity data. |
| \`data_set\` | \`(entity, data)\` | Set entity data. |
| \`match_get\` | \`(entity) :: map()\` | Get entity match criteria. |
| \`match_set\` | \`(entity, match)\` | Set entity match criteria. |
| \`make\` | \`(entity) :: entity\` | Create a new handle with the same options. |
| \`get_name\` | \`(entity) :: String.t()\` | Return the entity name. |

### Result shape

Entity operations return the bare result data (a value node — a map for
single-entity ops, a list for \`list\`) and raise a \`${Name}.Error\` on
failure. Wrap calls in \`try\`/\`rescue\` to handle errors.

The \`direct/2\` escape hatch never raises — it returns a result node you
branch on via \`Voxgig.Struct.getprop(result, "ok")\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`boolean()\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`integer()\` | HTTP status code. |
| \`headers\` | \`map()\` | Response headers. |
| \`data\` | \`any()\` | Parsed JSON response body. |

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
