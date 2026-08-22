
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'
  const EntityBase = model.const.Name + 'EntityBase'

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a
  // load/list/create/update/remove row only for operations at least one active
  // entity actually exposes — never document an operation no entity has.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(reqmatch, ctrl) throws -> Value` | Load a single entity by match criteria. Throws on error. |',
    list: '| `list` | `(reqmatch, ctrl) throws -> Value` | List entities matching the criteria (a Value list). Throws on error. |',
    create: '| `create` | `(reqdata, ctrl) throws -> Value` | Create a new entity. Throws on error. |',
    update: '| `update` | `(reqdata, ctrl) throws -> Value` | Update an existing entity. Throws on error. |',
    remove: '| `remove` | `(reqmatch, ctrl) throws -> Value` | Remove an entity. Throws on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `String` | API key for authentication. |\n'
    : ''

  Content(`### ${SDK}

\`\`\`swift
let client = ${SDK}(options)
\`\`\`

Creates a new SDK client. \`options\` is a \`VMap\` of \`Value\`.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`String\` | Base URL of the API server. |
| \`prefix\` | \`String\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`String\` | URL path suffix appended to all requests. |
| \`feature\` | \`VMap\` | Feature activation flags. |
| \`extend\` | \`VList\` | Additional Feature instances to load. |
| \`system\` | \`VMap\` | System overrides (e.g. custom \`fetch\` function). |

### testSDK

\`\`\`swift
let client = ${SDK}.testSDK(testopts, sdkopts)
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`nil\`.

### ${SDK} methods

| Method | Signature | Description |
| --- | --- | --- |
| \`optionsMap\` | \`() -> VMap\` | Deep copy of current SDK options. |
| \`getUtility\` | \`() -> Utility\` | Copy of the SDK utility object. |
| \`prepare\` | \`(fetchargs) throws -> VMap\` | Build an HTTP request definition without sending. Throws on error. |
| \`direct\` | \`(fetchargs) -> VMap\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ent.Name}\` | \`(entopts) -> ${EntityBase}\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data\` | \`(newdata?) -> Value\` | Get or set entity data. |
| \`matchv\` | \`(newmatch?) -> Value\` | Get or set entity match criteria. |
| \`make\` | \`() -> Entity\` | Create a new instance with the same options. |
| \`getName\` | \`() -> String\` | Return the entity name. |

### Result shape

Entity operations return the ENTITY (call data() for the record) (a \`Value\` map for
single-entity ops, a \`Value\` list for \`list\`) and throw on error. Wrap
calls in \`do\`/\`catch\` to handle failures.

The \`direct()\` escape hatch never throws — it returns a result \`VMap\` you
branch on via \`result.entries["ok"]\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`Bool\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`Int\` | HTTP status code. |
| \`headers\` | \`VMap\` | Response headers. |
| \`data\` | \`Value\` | Parsed JSON response body. |

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
