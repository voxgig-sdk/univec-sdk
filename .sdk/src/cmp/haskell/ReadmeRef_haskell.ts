
import { cmp, each, Content, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


// A type-correct Haskell `Value` literal for a field's canonical type.
function hsLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'VNum 1'
  if ('BOOLEAN' === k) return 'VBool True'
  if ('ARRAY' === k || 'OBJECT' === k) return 'VNoval'
  return `VStr "${placeholder}"`
}


// A readable Haskell type name for a field's canonical type.
function hsType(type: any): string {
  const k = canonKey(type)
  if ('STRING' === k) return 'String'
  if ('INTEGER' === k) return 'Int'
  if ('NUMBER' === k) return 'Double'
  if ('BOOLEAN' === k) return 'Bool'
  if ('ARRAY' === k) return '[Value]'
  return 'Value'
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'eLoad ent match ctrl :: IO Entity',
    returns: 'the entity',
    desc: 'Load a single entity matching the given criteria. Resolves to the ENTITY (read the record with `eDataGet`) and raises on error.',
  },
  list: {
    sig: 'eList ent match ctrl :: IO [Entity]',
    returns: 'one entity per record',
    desc: 'List entities matching the given criteria. The match is optional \u2014 pass an empty map to list all records. Resolves to one ENTITY per record and raises on error.',
  },
  create: {
    sig: 'eCreate ent data ctrl :: IO Entity',
    returns: 'the created entity',
    desc: 'Create a new entity with the given data. Resolves to the ENTITY (read the record with `eDataGet`) and raises on error.',
  },
  update: {
    sig: 'eUpdate ent data ctrl :: IO Entity',
    returns: 'the updated entity',
    desc: 'Update an existing entity. The data must include the entity `id`. Resolves to the ENTITY (read the record with `eDataGet`) and raises on error.',
  },
  remove: {
    sig: 'eRemove ent match ctrl :: IO Entity',
    returns: 'the removed entity',
    desc: 'Remove the entity matching the given criteria. Resolves to the ENTITY, marked deleted (`eDeleted`); it keeps the data it held. Raises on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## Client

### Constructors

\`\`\`haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

makeClient :: IO Sdk.Client
makeClient = do
  opts <- jo [("base", VStr "https://api.example.com")]
  Sdk.newSdk opts
\`\`\`

Construct a live SDK client.

**Functions:**

| Function | Signature | Description |
| --- | --- | --- |
| \`newSdk\` | \`Value -> IO Client\` | Construct a client from an options map. |
| \`newSdk0\` | \`IO Client\` | Construct a client with defaults. |

**Options (map keys):**

| Key | Type | Description |
| --- | --- | --- |
${isAuthActive(model) ? '| `apikey` | `String` | API key for authentication. |\n' : ''}| \`base\` | \`String\` | Base URL for API requests. |
| \`prefix\` | \`String\` | URL prefix appended after base. |
| \`suffix\` | \`String\` | URL suffix appended after path. |
| \`headers\` | \`Value\` | Custom headers for all requests. |
| \`feature\` | \`Value\` | Feature configuration. |
| \`system\` | \`Value\` | System overrides (e.g. custom fetch). |


### Test constructors

\`\`\`haskell
client <- Sdk.testSdk0
\`\`\`

\`testSdk :: Value -> Value -> IO Client\` constructs a test client with mock
features active (\`testSdk0 :: IO Client\` for the no-argument form). Pass
\`VNoval\` for defaults.


### Entity accessors

`)


    // Entity factory functions
    publishedEntities.map((ent: any) => {
      const eFn = hsVarName(ent.name)
      Content(`#### \`${eFn} :: Client -> Value -> IO Entity\`

Construct a \`${ent.Name}\` entity bound to the client. Pass \`VNoval\` for no initial options.

`)
    })


    Content(`### HTTP escape hatches

#### \`direct :: Client -> Value -> IO Value\` (module \`SdkFeatures\`)

Make a direct HTTP request to any API endpoint. Returns a result \`Value\` with
\`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape
hatch never raises — branch on \`getp result "ok"\`.

**Argument (map keys):**

| Key | Type | Description |
| --- | --- | --- |
| \`path\` | \`String\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`String\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`Value\` | Path parameter values. |
| \`query\` | \`Value\` | Query string parameters. |
| \`headers\` | \`Value\` | Request headers (merged with defaults). |
| \`body\` | \`Value\` | Request body (maps are JSON-serialized). |

#### \`prepare :: Client -> Value -> IO Value\` (module \`SdkFeatures\`)

Prepare a fetch definition without sending. Returns the \`fetchdef\` and raises on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      const idF = entityIdField(ent)
      const eFn = hsVarName(ent.name)

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
\`\`\`

`)


      // Field schema
      if (fields.length > 0) {
        Content(`### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
`)
        each(fields, (field: any) => {
          const req = field.req ? 'Yes' : 'No'
          const desc = field.short || ''
          Content(`| \`${field.name}\` | \`${hsType(field.type)}\` | ${req} | ${desc} |
`)
        })

        Content(`
`)

        // Field operations breakdown
        const hasFieldOps = fields.some((f: any) => f.op && Object.keys(f.op).length > 0)
        if (hasFieldOps) {
          const opcols = ['load', 'list', 'create', 'update', 'remove']
            .filter((op: string) => opnames.includes(op) && ent.op[op]?.active !== false)
          Content(`### Field Usage by Operation

| Field | ${opcols.join(' | ')} |
| --- | ${opcols.map(() => '---').join(' | ')} |
`)
          each(fields, (field: any) => {
            const fops = field.op || {}
            const cols = opcols.map((op: string) => {
              const fop = fops[op]
              if (null == fop) return '-'
              if (fop.active === false) return '-'
              return 'Yes'
            })
            Content(`| \`${field.name}\` | ${cols.join(' | ')} |
`)
          })

          Content(`
`)
        }
      }


      // Operation details
      if (opnames.length > 0) {
        Content(`### Operations

`)

        opnames.map((opname: string) => {
          const info = OP_SIGNATURES[opname]
          if (!info) return

          Content(`#### \`${info.sig}\`

${info.desc}

`)

          if ('load' === opname || 'remove' === opname) {
            const matchItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const arg = 0 < matchItems.length
              ? `[${matchItems.map((it: any) =>
                `("${it.name}", ${hsLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)})`).join(', ')}]`
              : '[]'
            Content(`\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  match <- jo ${arg}
  ctrl <- emptyMap
  result <- Sdk.e${opname.charAt(0).toUpperCase() + opname.slice(1)} ent match ctrl
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  match <- emptyMap
  ctrl <- emptyMap
  results <- Sdk.eList ent match ctrl   -- one ENTITY per record
  datas <- mapM Sdk.eDataGet results
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  d <- jo
    [`)
            createItems.map((it: any, i: number) => {
              const bracket = 0 === i ? ' ' : ', '
              Content(`${bracket}("${it.name}", ${hsLit(it.type, 'example_' + it.name)})   -- ${hsType(it.type)}
    `)
            })
            Content(`]
  ctrl <- emptyMap
  result <- Sdk.eCreate ent d ctrl   -- the ENTITY
  d2 <- Sdk.eDataGet result
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any, i: number) => {
              const bracket = 0 === i ? ' ' : ', '
              return `${bracket}("${it.name}", ${hsLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)})`
            }).join('\n    ')
            Content(`\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  d <- jo
    [${updateLines}
    ]  -- fields to update
  ctrl <- emptyMap
  result <- Sdk.eUpdate ent d ctrl   -- the ENTITY
  d2 <- Sdk.eDataGet result
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Fields

#### \`eDataGet :: IO Value\`

Get the entity data.

#### \`eDataSet :: Value -> IO ()\`

Set the entity data.

#### \`eStream :: String -> Value -> Value -> IO [Value]\`

Run an operation as a lazy stream of result items.

#### \`eMake :: IO Entity\`

Create a new \`${ent.Name}\` entity with the same options.

#### \`eName :: String\`

The entity name.

`)
    })


    // Features section
    const activeFeatures = each(feature).filter((f: any) => f.active)
    if (activeFeatures.length > 0) {
      Content(`
---

## Features

| Feature | Version | Description |
| --- | --- | --- |
`)

      activeFeatures.map((f: any) => {
        Content(`| \`${f.name}\` | ${f.version || '0.0.1'} | ${f.title || ''} |
`)
      })

      Content(`

Features are activated via the \`feature\` option:

`)

      Content(`\`\`\`haskell
  active <- jo [("active", VBool True)]
  featureCfg <- jo
    [`)
      activeFeatures.map((f: any, i: number) => {
        const bracket = 0 === i ? ' ' : ', '
        Content(`${bracket}("${f.name}", active)
    `)
      })
      Content(`]
  opts <- jo [("feature", featureCfg)]
  client <- Sdk.newSdk opts
\`\`\`

`)
    }

  })
})




export {
  ReadmeRef
}
