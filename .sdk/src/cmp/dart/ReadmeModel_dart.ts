
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { dartPackageName } from './Package_dart'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)
  const pkg = dartPackageName(model)

  // Model-driven op rows for the shared entity interface: emit a row only for
  // operations at least one active entity actually exposes.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(reqmatch, [ctrl]) -> Future<dynamic>` | Load a single entity by match criteria. Throws on error. |',
    list: '| `list` | `(reqmatch, [ctrl]) -> Future<List>` | List entities matching the criteria (a list of entity instances). Throws on error. |',
    create: '| `create` | `(reqdata, [ctrl]) -> Future<dynamic>` | Create a new entity. Throws on error. |',
    update: '| `update` | `(reqdata, [ctrl]) -> Future<dynamic>` | Update an existing entity. Throws on error. |',
    remove: '| `remove` | `(reqmatch, [ctrl]) -> Future<dynamic>` | Remove an entity. Throws on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `String` | API key for authentication. |\n'
    : ''

  Content(`### ${model.const.Name}SDK

\`\`\`dart
import 'package:${pkg}/${model.const.Name}SDK.dart';

final client = ${model.const.Name}SDK(options);
\`\`\`

Creates a new SDK client.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`String\` | Base URL of the API server. |
| \`prefix\` | \`String\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`String\` | URL path suffix appended to all requests. |
| \`feature\` | \`Map\` | Feature activation flags. |
| \`extend\` | \`List\` | Additional Feature instances to load. |
| \`system\` | \`Map\` | System overrides (e.g. custom \`fetch\` function). |

### test

\`\`\`dart
final client = ${model.const.Name}SDK.test(testopts, sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`null\`.

### ${model.const.Name}SDK methods

| Method | Signature | Description |
| --- | --- | --- |
| \`options\` | \`() -> Map\` | Deep copy of current SDK options. |
| \`utility\` | \`() -> Utility\` | The SDK utility object. |
| \`prepare\` | \`([fetchargs]) -> Future\` | Build an HTTP request definition without sending. Returns an error value on failure. |
| \`direct\` | \`([fetchargs]) -> Future<Map>\` | Build and send an HTTP request. Returns a result map (branch on \`ok\`); never throws. |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ent.Name}\` | \`([entopts]) -> ${ent.Name}Entity\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data\` | \`([d]) -> Map\` | Get (or, with an argument, set) entity data. |
| \`match\` | \`([m]) -> Map\` | Get (or, with an argument, set) entity match criteria. |
| \`make\` | \`() -> Entity\` | Create a new instance with the same options. |
| \`entopts\` | \`() -> Map\` | Return the entity options. |
| \`Name\` | \`String\` | The entity name (a public field). |

### Result shape

Entity operations return the ENTITY (call data() for the record) (a \`Map\` for single-entity
ops, a \`List\` of entity instances for \`list\`) and throw on error. Wrap calls
in \`try\`/\`catch\` to handle failures.

The \`direct()\` escape hatch never throws — it returns a result \`Map\` you
branch on via \`result['ok']\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`bool\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`int\` | HTTP status code. |
| \`headers\` | \`Map\` | Response headers. |
| \`data\` | \`dynamic\` | Parsed JSON response body. |

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
