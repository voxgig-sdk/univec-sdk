
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a row only for
  // operations at least one active entity actually exposes — never document an
  // operation no entity has.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(ent reqmatch ctrl) -> map` | Load a single entity by match criteria. Raises on error. |',
    list: '| `list` | `(ent reqmatch ctrl) -> vector` | List entities matching the criteria. Raises on error. |',
    create: '| `create` | `(ent reqdata ctrl) -> map` | Create a new entity. Raises on error. |',
    update: '| `update` | `(ent reqdata ctrl) -> map` | Update an existing entity. Raises on error. |',
    remove: '| `remove` | `(ent reqmatch ctrl) -> map` | Remove an entity. Raises on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### make-sdk

\`\`\`clojure
(require '[sdk.api :as api]
         '[voxgig.struct :as vs])

(def client (api/make-sdk options))
\`\`\`

Creates a new SDK client. \`options\` is a \`voxgig.struct\` map (or \`nil\`).

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`map\` | Feature activation flags. |
| \`extend\` | \`vector\` | Additional feature atoms to load. |
| \`system\` | \`map\` | System overrides (e.g. custom \`fetch\` fn). |

### test-sdk

\`\`\`clojure
(def client (api/test-sdk testopts sdkopts))
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`nil\`.

### Client functions

| Function | Signature | Description |
| --- | --- | --- |
| \`options-map\` | \`(client) -> map\` | Deep copy of current SDK options. |
| \`get-utility\` | \`(client) -> utility\` | Copy of the SDK utility object. |
| \`prepare\` | \`(client fetchargs) -> map\` | Build an HTTP request definition without sending. Raises on error. |
| \`direct\` | \`(client fetchargs) -> map\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ent.name}\` | \`(client data) -> ${ent.Name} entity\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface. Operations are functions in the
entity namespace (\`sdk.entity.<name>\`); state accessors are stored on the
entity map and are called via keyword lookup.

| Member | Signature | Description |
| --- | --- | --- |
${opRows}
| \`:data-get\` | \`() -> map\` | Get entity data. |
| \`:data-set\` | \`(data)\` | Set entity data. |
| \`:match-get\` | \`() -> map\` | Get entity match criteria. |
| \`:match-set\` | \`(match)\` | Set entity match criteria. |
| \`:make\` | \`() -> entity\` | Create a new instance with the same options. |
| \`:get-name\` | \`() -> string\` | Return the entity name. |

State accessors are called by looking up the fn and applying it, e.g.
\`((:data-get ent))\` or \`((:data-set ent) (vs/jm "k" "v"))\`.

### Result shape

Entity operations return the bare result data (a \`map\` for single-entity
ops, a \`vector\` for \`list\`) and raise (via \`ex-info\`) on error. Wrap
calls in \`try\`/\`catch\` to handle failures.

The \`direct\` escape hatch never raises — it returns a result \`map\` you
branch on via \`(vs/getprop result "ok")\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`boolean\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`long\` | HTTP status code. |
| \`headers\` | \`map\` | Response headers. |
| \`data\` | \`any\` | Parsed JSON response body. |

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
