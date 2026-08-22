
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


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
    load: '| `load` | `(reqmatch, ctrl) -> Value` | Load a single entity by match criteria. Throws on error. |',
    list: '| `list` | `(reqmatch, ctrl) -> Value` | List entities matching the criteria (a Value list). Throws on error. |',
    create: '| `create` | `(reqdata, ctrl) -> Value` | Create a new entity. Throws on error. |',
    update: '| `update` | `(reqdata, ctrl) -> Value` | Update an existing entity. Throws on error. |',
    remove: '| `remove` | `(reqmatch, ctrl) -> Value` | Remove an entity. Throws on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `std::string` | API key for authentication. |\n'
    : ''

  Content(`### ${model.const.Name}SDK

\`\`\`cpp
#include "core/sdk.hpp"

using namespace sdk;

auto client = std::make_shared<${model.const.Name}SDK>(options);
\`\`\`

Creates a new SDK client. \`options\` is an \`sdk::Value\` map.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`std::string\` | Base URL of the API server. |
| \`prefix\` | \`std::string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`std::string\` | URL path suffix appended to all requests. |
| \`feature\` | \`Value\` | Feature activation flags. |
| \`system\` | \`Value\` | System overrides. |

### testSDK

\`\`\`cpp
auto client = ${model.const.Name}SDK::testSDK(testopts, sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be
\`Value::undef()\`; a no-arg \`${model.const.Name}SDK::testSDK()\` overload is
also provided.

### ${model.const.Name}SDK methods

| Method | Signature | Description |
| --- | --- | --- |
| \`optionsMap\` | \`() -> Value\` | Deep copy of current SDK options. |
| \`getUtility\` | \`() -> UtilityPtr\` | Copy of the SDK utility object. |
| \`prepare\` | \`(fetchargs) -> Value\` | Build an HTTP request definition without sending. Throws on error. |
| \`direct\` | \`(fetchargs) -> Value\` | Build and send an HTTP request. Returns a result Value (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const acc = cppVarName(ent.name)
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${acc}\` | \`(entopts) -> std::shared_ptr<${ent.Name}Entity>\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data\` | \`(arg) -> Value\` | Get (no arg) or set (with arg) entity data. |
| \`match\` | \`(arg) -> Value\` | Get (no arg) or set (with arg) entity match criteria. |
| \`make\` | \`() -> EntityPtr\` | Create a new instance with the same options. |
| \`getName\` | \`() -> std::string\` | Return the entity name. |

### Result shape

Entity operations return the bare result data (a map \`Value\` for
single-entity ops, a list \`Value\` for \`list\`) and throw
\`sdk::SdkErrorPtr\` on error. Wrap calls in \`try\`/\`catch\` to handle
failures.

The \`direct()\` escape hatch never throws — it returns a result \`Value\`
you branch on via \`getp(result, "ok")\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`bool\` | \`true\` if the HTTP status is 2xx. |
| \`status\` | \`int\` | HTTP status code. |
| \`headers\` | \`Value\` | Response headers. |
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
