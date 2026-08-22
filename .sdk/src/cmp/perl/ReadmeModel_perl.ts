
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows: emit a row only for operations at least one active
  // entity actually exposes — never document an operation no entity has.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `load` | `($reqmatch, $ctrl) -> hashref` | Load a single entity by match criteria. Dies on error. |',
    list: '| `list` | `($reqmatch, $ctrl) -> arrayref` | List entities matching the criteria. Dies on error. |',
    create: '| `create` | `($reqdata, $ctrl) -> hashref` | Create a new entity. Dies on error. |',
    update: '| `update` | `($reqdata, $ctrl) -> hashref` | Update an existing entity. Dies on error. |',
    remove: '| `remove` | `($reqmatch, $ctrl) -> hashref` | Remove an entity. Dies on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `string` | API key for authentication. |\n'
    : ''

  Content(`### ${model.const.Name}SDK

\`\`\`perl
use lib 'lib';
use ${model.const.Name}SDK;

my $client = ${model.const.Name}SDK->new($options);
\`\`\`

Creates a new SDK client.

| Option | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`string\` | Base URL of the API server. |
| \`prefix\` | \`string\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`string\` | URL path suffix appended to all requests. |
| \`feature\` | \`hashref\` | Feature activation flags. |
| \`extend\` | \`arrayref\` | Additional feature instances to load. |
| \`system\` | \`hashref\` | System overrides (e.g. custom \`fetch\` coderef). |

### test

\`\`\`perl
my $client = ${model.const.Name}SDK->test($testopts, $sdkopts);
\`\`\`

Creates a test-mode client with mock transport. Both arguments may be \`undef\`.

### ${model.const.Name}SDK methods

| Method | Signature | Description |
| --- | --- | --- |
| \`options_map\` | \`() -> hashref\` | Deep copy of current SDK options. |
| \`get_utility\` | \`() -> utility\` | Copy of the SDK utility object. |
| \`prepare\` | \`($fetchargs) -> hashref\` | Build an HTTP request definition without sending. Dies on error. |
| \`direct\` | \`($fetchargs) -> hashref\` | Build and send an HTTP request. Returns a result hashref (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${ent.Name}\` | \`($data) -> ${ent.Name} entity\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same interface.

| Method | Signature | Description |
| --- | --- | --- |
${opRows}
| \`data_get\` | \`() -> hashref\` | Get entity data. |
| \`data_set\` | \`($data)\` | Set entity data. |
| \`match_get\` | \`() -> hashref\` | Get entity match criteria. |
| \`match_set\` | \`($match)\` | Set entity match criteria. |
| \`make\` | \`() -> entity\` | Create a new instance with the same options. |
| \`get_name\` | \`() -> string\` | Return the entity name. |

### Result shape

Entity operations return the ENTITY (call data_get for the record) (a \`hashref\` for single-entity
ops, an \`arrayref\` for \`list\`) and die on error. Wrap calls in
\`eval { ... }\` and inspect \`$@\` to handle failures.

The \`direct()\` escape hatch never dies — it returns a result \`hashref\`
you branch on via \`$result->{ok}\`:

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`boolean\` | True if the HTTP status is 2xx. |
| \`status\` | \`integer\` | HTTP status code. |
| \`headers\` | \`hashref\` | Response headers. |
| \`data\` | \`any\` | Parsed JSON response body. |

On error, \`ok\` is false and \`err\` contains the error value.

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
