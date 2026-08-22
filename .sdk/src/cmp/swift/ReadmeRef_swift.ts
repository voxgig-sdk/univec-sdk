
import { cmp, each, Content, canonToType, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { swiftVarName } from './utility_swift'


// Type names come from the shared canonToType 'swift' column (single source of truth).

// A type-correct Swift `Value` literal for a field's canonical type.
function swiftLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '.int(1)'
  if ('NUMBER' === k) return '.double(1.0)'
  if ('BOOLEAN' === k) return '.bool(true)'
  if ('ARRAY' === k) return '.list([])'
  if ('OBJECT' === k) return '.map(VMap())'
  return `.string("${placeholder}")`
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'load(reqmatch, ctrl) throws -> Value',
    returns: 'the entity data',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and throws on error.',
  },
  list: {
    sig: 'list(reqmatch, ctrl) throws -> Value',
    returns: 'a Value list of entities',
    desc: 'List entities matching the given criteria. The match is optional — call `list(nil, nil)` to list all records. Returns a Value list and throws on error.',
  },
  create: {
    sig: 'create(reqdata, ctrl) throws -> Value',
    returns: 'the created entity data',
    desc: 'Create a new entity with the given data. Returns the created entity data and throws on error.',
  },
  update: {
    sig: 'update(reqdata, ctrl) throws -> Value',
    returns: 'the updated entity data',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and throws on error.',
  },
  remove: {
    sig: 'remove(reqmatch, ctrl) throws -> Value',
    returns: 'the removed entity data',
    desc: 'Remove the entity matching the given criteria. Throws on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${SDK}

### Constructor

`)

    Content(`\`\`\`swift
let client = ${SDK}(options)
\`\`\`

Create a new SDK client instance. \`options\` is a \`VMap\` of \`Value\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`options\` | \`VMap\` | SDK configuration options. |
${isAuthActive(model) ? '| \`options["apikey"]\` | \`String\` | API key for authentication. |\n' : ''}| \`options["base"]\` | \`String\` | Base URL for API requests. |
| \`options["prefix"]\` | \`String\` | URL prefix appended after base. |
| \`options["suffix"]\` | \`String\` | URL suffix appended after path. |
| \`options["headers"]\` | \`VMap\` | Custom headers for all requests. |
| \`options["feature"]\` | \`VMap\` | Feature configuration. |
| \`options["system"]\` | \`VMap\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Static Methods

`)

    Content(`#### \`${SDK}.testSDK(testopts, sdkopts)\`

Create a test client with mock features active. Both arguments may be \`nil\`.

\`\`\`swift
let client = ${SDK}.testSDK(nil, nil)
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${ent.Name}(entopts)\`

Create a new \`${ent.Name}\` entity instance. Pass \`nil\` for no initial
options.

`)
    })


    Content(`#### \`optionsMap() -> VMap\`

Return a deep copy of the current SDK options.

#### \`getUtility() -> Utility\`

Return a copy of the SDK utility object.

#### \`direct(fetchargs) -> VMap\`

Make a direct HTTP request to any API endpoint. Returns a result \`VMap\`
with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure).
This escape hatch never throws — branch on \`result.entries["ok"]\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`fetchargs["path"]\` | \`String\` | URL path with optional \`{param}\` placeholders. |
| \`fetchargs["method"]\` | \`String\` | HTTP method (default: \`"GET"\`). |
| \`fetchargs["params"]\` | \`VMap\` | Path parameter values. |
| \`fetchargs["query"]\` | \`VMap\` | Query string parameters. |
| \`fetchargs["headers"]\` | \`VMap\` | Request headers (merged with defaults). |
| \`fetchargs["body"]\` | \`Value\` | Request body (maps are JSON-serialized). |

**Returns:** \`VMap\`

#### \`prepare(fetchargs) throws -> VMap\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and throws on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      // Model-driven id key: null when this entity has no id-like field.
      const idF = entityIdField(ent)
      // Sanitise the local variable name — swiftVarName guards Swift keywords.
      const eVar = swiftVarName(ent.name)
      const accessor = ent.Name

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`swift
let ${eVar} = client.${accessor}()
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
          Content(`| \`${field.name}\` | \`${canonToType(field.type, target.name)}\` | ${req} | ${desc} |
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
              ? `VMap([${matchItems.map((it: any) =>
                `("${it.name}", ${swiftLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)})`).join(', ')}])`
              : 'nil'
            Content(`\`\`\`swift
let result = try client.${accessor}().${opname}(${arg}, nil)
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`swift
let results = try client.${accessor}().list(nil, nil)
print(results)
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`swift
let result = try client.${accessor}().create(VMap([
`)
            createItems.map((it: any, i: number) => {
              const comma = i < createItems.length - 1 ? ',' : ''
              Content(`    ("${it.name}", ${swiftLit(it.type, 'example_' + it.name)})${comma}  // ${canonToType(it.type, target.name)}
`)
            })
            Content(`]), nil)
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any, i: number) => {
              const comma = i < updateItems.length - 1 ? ',' : ''
              return `    ("${it.name}", ${swiftLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)})${comma}\n`
            }).join('')
            Content(`\`\`\`swift
let result = try client.${accessor}().update(VMap([
${updateLines}]), nil)
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data(newdata?) -> Value\`

Get or set the entity data.

#### \`matchv(newmatch?) -> Value\`

Get or set the entity match criteria.

#### \`make() -> Entity\`

Create a new \`${ent.Name}\` entity instance with the same options.

#### \`getName() -> String\`

Return the entity name.

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

      Content(`\`\`\`swift
let feature = VMap()
`)
      activeFeatures.map((f: any) => {
        Content(`feature.entries["${f.name}"] = .map([("active", .bool(true))])
`)
      })
      Content(`let options = VMap()
options.entries["feature"] = .map(feature)
let client = ${SDK}(options)
\`\`\`

`)
    }

  })
})


export {
  ReadmeRef
}
