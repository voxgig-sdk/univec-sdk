
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { crateIdent, rustVarName } from './utility_rust'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const rustcrate = crateIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity interface: emit a row only for
  // operations at least one active entity actually exposes.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `(reqmatch: Value, ctrl: Value) -> Result<Value, ' + model.const.Name + 'Error>` | Load a single entity by match criteria. |',
    list: '| `list` | `(reqmatch: Value, ctrl: Value) -> Result<Value, ' + model.const.Name + 'Error>` | List entities matching the criteria (Ok is a `Value::List`). |',
    create: '| `create` | `(reqdata: Value, ctrl: Value) -> Result<Value, ' + model.const.Name + 'Error>` | Create a new entity. |',
    update: '| `update` | `(reqdata: Value, ctrl: Value) -> Result<Value, ' + model.const.Name + 'Error>` | Update an existing entity. |',
    remove: '| `remove` | `(reqmatch: Value, ctrl: Value) -> Result<Value, ' + model.const.Name + 'Error>` | Remove an entity. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### ${model.const.Name}SDK

\`\`\`rust
use ${rustcrate}::{${model.const.Name}SDK, Value};

let client = ${model.const.Name}SDK::new(options);
\`\`\`

Creates a new SDK client. \`options\` is a \`Value\` map (\`Value::Noval\` for
none) carrying any of the following keys:

| Option | Value type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`map\` | Feature activation flags. |
| \`system\` | \`map\` | System overrides (e.g. a custom fetcher). |

### test_sdk

\`\`\`rust
use ${rustcrate}::{test_sdk, Value};

let client = test_sdk(testopts, sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be
\`Value::Noval\`.

### ${model.const.Name}SDK methods

| Method | Signature | Description |
| --- | --- | --- |
| \`options_map\` | \`() -> Value\` | Deep copy of the current SDK options. |
| \`get_utility\` | \`() -> Rc<Utility>\` | Copy of the SDK utility object. |
| \`prepare\` | \`(fetchargs: Value) -> Result<Value, ${model.const.Name}Error>\` | Build an HTTP request definition without sending. |
| \`direct\` | \`(fetchargs: Value) -> Result<Value, ${model.const.Name}Error>\` | Build and send an HTTP request. \`Ok\` is a result map (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${rustVarName(ent.name)}\` | \`(entopts: Value) -> Rc<${ent.Name}Entity>\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data\` | \`(args: Option<&Value>) -> Value\` | Get entity data (pass \`Some(&map)\` to set). |
| \`matchv\` | \`(args: Option<&Value>) -> Value\` | Get entity match criteria (pass \`Some(&map)\` to set). |
| \`make\` | \`() -> Rc<dyn Entity>\` | Create a new instance with the same options. |
| \`get_name\` | \`() -> String\` | Return the entity name. |

### Result shape

Entity operations return \`Result<Value, ${model.const.Name}Error>\` — the
bare result data on \`Ok\` (a \`Value::Map\` for single-entity ops, a
\`Value::List\` for \`list\`) and the branded error on \`Err\`.

The \`direct()\` escape hatch resolves to \`Ok\` even on a non-2xx response —
it returns a result \`Value::Map\` you branch on via \`getp(&result, "ok")\`:

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
