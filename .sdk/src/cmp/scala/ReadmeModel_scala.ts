
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { scalaVarName } from './utility_scala'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a
  // load/list/create/update/remove row only for operations at least one active
  // entity actually exposes — never document an operation no entity has.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(reqmatch, ctrl) -> Object` | Load a single entity by match criteria. Raises on error. |',
    list: '| `list` | `(reqmatch, ctrl) -> Object` | List entities matching the criteria (an aggregate list). Raises on error. |',
    create: '| `create` | `(reqdata, ctrl) -> Object` | Create a new entity. Raises on error. |',
    update: '| `update` | `(reqdata, ctrl) -> Object` | Update an existing entity. Raises on error. |',
    remove: '| `remove` | `(reqmatch, ctrl) -> Object` | Remove an entity. Raises on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `String` | API key for authentication. |\n'
    : ''

  Content(`### ${SDK}

\`\`\`scala
val client = new ${SDK}(options)
\`\`\`

Creates a new SDK client. \`options\` is a \`java.util.Map[String, Object]\`.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`String\` | Base URL of the API server. |
| \`prefix\` | \`String\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`String\` | URL path suffix appended to all requests. |
| \`feature\` | \`Map\` | Feature activation flags. |
| \`extend\` | \`List\` | Additional Feature instances to load. |
| \`system\` | \`Map\` | System overrides (e.g. custom \`fetch\` function). |

### testSDK

\`\`\`scala
val client = ${SDK}.testSDK(testopts, sdkopts)
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`null\`.

### ${SDK} methods

| Method | Signature | Description |
| --- | --- | --- |
| \`optionsMap\` | \`() -> Map\` | Deep copy of current SDK options. |
| \`getUtility\` | \`() -> Utility\` | Copy of the SDK utility object. |
| \`prepare\` | \`(fetchargs) -> Map\` | Build an HTTP request definition without sending. Raises on error. |
| \`direct\` | \`(fetchargs) -> Map\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${scalaVarName(ent.name)}\` | \`(entopts) -> SdkEntity\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data\` | \`(newdata*) -> Object\` | Get or set entity data. |
| \`matchArgs\` | \`(newmatch*) -> Object\` | Get or set entity match criteria. |
| \`make\` | \`() -> Entity\` | Create a new instance with the same options. |
| \`getName\` | \`() -> String\` | Return the entity name. |

### Result shape

Entity operations return the ENTITY (call data() for the record) (a \`Map\` for single-entity
ops, an aggregate \`List\` for \`list\`) as \`Object\` and raise on error. Wrap
calls in \`try\`/\`catch\` to handle failures.

The \`direct()\` escape hatch never raises — it returns a result
\`java.util.Map[String, Object]\` you branch on via \`result.get("ok")\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`Boolean\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`Int\` | HTTP status code. |
| \`headers\` | \`Map\` | Response headers. |
| \`data\` | \`Object\` | Parsed JSON response body. |

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
Operations: ${opnames.join(', ')}.

API path: \`${path}\`

`)
  })

})


export {
  ReadmeModel
}
