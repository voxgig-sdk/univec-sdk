
import { cmp, each, Content, isAuthActive } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


const ReadmeModel = cmp(function ReadmeModel(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const entityList = each(entity).filter((e: any) => e.active !== false)

  // Model-driven op rows for the shared entity record interface: emit a row
  // only for operations at least one active entity actually exposes.
  const opUnion = new Set<string>()
  entityList.forEach((e: any) => Object.keys(e.op || {})
    .forEach((o: string) => { if (e.op[o] && e.op[o].active !== false) opUnion.add(o) }))
  const opRowDefs: Record<string, string> = {
    load: '| `eLoad` | `Value -> Value -> IO Entity` | Load a single entity by match criteria. Resolves to the entity. Raises on error. |',
    list: '| `eList` | `Value -> Value -> IO [Entity]` | List entities matching the criteria. Resolves to one entity per record. Raises on error. |',
    create: '| `eCreate` | `Value -> Value -> IO Entity` | Create a new entity. Resolves to the entity. Raises on error. |',
    update: '| `eUpdate` | `Value -> Value -> IO Entity` | Update an existing entity. Resolves to the entity. Raises on error. |',
    remove: '| `eRemove` | `Value -> Value -> IO Entity` | Remove an entity. Resolves to the entity, marked deleted. Raises on error. |',
  }
  const opRows = ['load', 'list', 'create', 'update', 'remove']
    .filter((o) => opUnion.has(o)).map((o) => opRowDefs[o]).join('\n')

  const apikeyOptionRow = isAuthActive(model)
    ? '| `apikey` | `String` | API key for authentication. |\n'
    : ''

  Content(`### Client constructors

\`\`\`haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

makeClient :: IO Sdk.Client
makeClient = do
  opts <- jo [("base", VStr "https://api.example.com")]
  Sdk.newSdk opts
\`\`\`

\`newSdk :: Value -> IO Client\` constructs a client from an options map;
\`newSdk0 :: IO Client\` is the no-argument convenience form.

| Option (map key) | Type | Description |
| --- | --- | --- |
${apikeyOptionRow}| \`base\` | \`String\` | Base URL of the API server. |
| \`prefix\` | \`String\` | URL path prefix prepended to all requests. |
| \`suffix\` | \`String\` | URL path suffix appended to all requests. |
| \`headers\` | \`Value\` | Custom headers for all requests. |
| \`feature\` | \`Value\` | Feature activation flags. |
| \`system\` | \`Value\` | System overrides (e.g. custom \`fetch\` function). |

### Test client

\`\`\`haskell
client <- Sdk.testSdk testopts sdkopts
\`\`\`

\`testSdk :: Value -> Value -> IO Client\` constructs a test-mode client with
mock transport (\`testSdk0 :: IO Client\` for the no-argument form). Pass
\`VNoval\` for defaults.

### Client functions

| Function | Signature | Description |
| --- | --- | --- |
| \`newSdk\` | \`Value -> IO Client\` | Construct a live client from options. |
| \`newSdk0\` | \`IO Client\` | Construct a live client with defaults. |
| \`testSdk\` | \`Value -> Value -> IO Client\` | Construct a test-mode client. |
| \`prepare\` | \`Client -> Value -> IO Value\` | Build an HTTP request definition without sending. Raises on error. |
| \`direct\` | \`Client -> Value -> IO Value\` | Build and send an HTTP request. Returns a result \`Value\` (branch on \`ok\`). |
`)

  each(entityList, (ent: any) => {
    const eFn = hsVarName(ent.name)
    const article = /^[aeiou]/i.test(ent.Name) ? 'an' : 'a'
    Content(`| \`${eFn}\` | \`Client -> Value -> IO Entity\` | Create ${article} ${ent.Name} entity instance. |
`)
  })

  Content(`
### Entity interface

All entities share the same record interface (fields of the \`Entity\` type).

| Field | Signature | Description |
| --- | --- | --- |
${opRows}
| \`eDataGet\` | \`IO Value\` | Get entity data. |
| \`eDataSet\` | \`Value -> IO ()\` | Set entity data. |
| \`eStream\` | \`String -> Value -> Value -> IO [Value]\` | Run an op as a lazy stream of items. |
| \`eMake\` | \`IO Entity\` | Create a new instance with the same options. |
| \`eName\` | \`String\` | The entity name. |

### Result shape

Entity operations resolve to the ENTITY, not the raw record \u2014 \`eList\` to
one entity per record \u2014 and raise on error. The record is reached through
\`eDataGet\`, which returns the entity's data container. \`eRemove\` resolves to
the entity marked deleted (\`eDeleted\`); it keeps the data it held. Wrap calls
in \`Control.Exception.try\` to handle failures.

The \`direct\` escape hatch never raises — it returns a result \`Value\`
you branch on via its \`ok\` field (read with \`getp result "ok"\`):

| Key | Type | Description |
| --- | --- | --- |
| \`ok\` | \`Bool\` | \`True\` if the HTTP status is 2xx. |
| \`status\` | \`Int\` | HTTP status code. |
| \`headers\` | \`Value\` | Response headers. |
| \`data\` | \`Value\` | Parsed JSON response body. |

On error, \`ok\` is \`False\` and \`err\` carries the error value.

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
