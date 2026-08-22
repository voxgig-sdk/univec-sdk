
import { cmp, each, Content, canonToType, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { scalaVarName } from './utility_scala'


// Type names come from the shared canonToType 'scala' column (single source of truth).

// A type-correct Scala literal for a field's canonical type.
function scalaLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'java.util.List.of()'
  if ('OBJECT' === k) return 'java.util.Map.of()'
  return `"${placeholder}"`
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'load(reqmatch, ctrl) -> Object',
    returns: 'the entity data',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and raises on error.',
  },
  list: {
    sig: 'list(reqmatch, ctrl) -> Object',
    returns: 'an aggregate list of entities',
    desc: 'List entities matching the given criteria. The match is optional — call `list(null, null)` to list all records. Returns an aggregate list and raises on error.',
  },
  create: {
    sig: 'create(reqdata, ctrl) -> Object',
    returns: 'the created entity data',
    desc: 'Create a new entity with the given data. Returns the created entity data and raises on error.',
  },
  update: {
    sig: 'update(reqdata, ctrl) -> Object',
    returns: 'the updated entity data',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and raises on error.',
  },
  remove: {
    sig: 'remove(reqmatch, ctrl) -> Object',
    returns: 'the removed entity data',
    desc: 'Remove the entity matching the given criteria. Raises on error.',
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

    Content(`\`\`\`scala
val client = new ${SDK}(options)
\`\`\`

Create a new SDK client instance. \`options\` is a \`java.util.Map[String, Object]\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`options\` | \`Map\` | SDK configuration options. |
${isAuthActive(model) ? '| \`options["apikey"]\` | \`String\` | API key for authentication. |\n' : ''}| \`options["base"]\` | \`String\` | Base URL for API requests. |
| \`options["prefix"]\` | \`String\` | URL prefix appended after base. |
| \`options["suffix"]\` | \`String\` | URL suffix appended after path. |
| \`options["headers"]\` | \`Map\` | Custom headers for all requests. |
| \`options["feature"]\` | \`Map\` | Feature configuration. |
| \`options["system"]\` | \`Map\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Static Methods

`)

    Content(`#### \`${SDK}.testSDK(testopts, sdkopts)\`

Create a test client with mock features active. Both arguments may be \`null\`.

\`\`\`scala
val client = ${SDK}.testSDK(null, null)
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${scalaVarName(ent.name)}(entopts)\`

Create a new \`${ent.Name}\` entity instance (returns \`SdkEntity\`). Pass
\`null\` for no initial options.

`)
    })


    Content(`#### \`optionsMap() -> Map\`

Return a deep copy of the current SDK options.

#### \`getUtility() -> Utility\`

Return a copy of the SDK utility object.

#### \`direct(fetchargs) -> Map\`

Make a direct HTTP request to any API endpoint. Returns a result
\`java.util.Map[String, Object]\` with \`ok\`, \`status\`, \`headers\`, and
\`data\` (or \`err\` on failure). This escape hatch never raises — branch on
\`result.get("ok")\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`fetchargs["path"]\` | \`String\` | URL path with optional \`{param}\` placeholders. |
| \`fetchargs["method"]\` | \`String\` | HTTP method (default: \`"GET"\`). |
| \`fetchargs["params"]\` | \`Map\` | Path parameter values. |
| \`fetchargs["query"]\` | \`Map\` | Query string parameters. |
| \`fetchargs["headers"]\` | \`Map\` | Request headers (merged with defaults). |
| \`fetchargs["body"]\` | \`Object\` | Request body (maps are JSON-serialized). |

**Returns:** \`java.util.Map[String, Object]\`

#### \`prepare(fetchargs) -> Map\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and raises on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      // Model-driven id key: null when this entity has no id-like field.
      const idF = entityIdField(ent)
      // Sanitise the local variable name — scalaVarName guards Scala keywords.
      const eVar = scalaVarName(ent.name)
      const accessor = scalaVarName(ent.name)

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`scala
val ${eVar} = client.${accessor}(null)
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
              ? `java.util.Map.of(${matchItems.map((it: any) =>
                `"${it.name}", ${scalaLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}`).join(', ')})`
              : 'null'
            Content(`\`\`\`scala
val result = client.${accessor}(null).${opname}(${arg}, null)
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`scala
val results = client.${accessor}(null).list(null, null)
println(results)
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`scala
val result = client.${accessor}(null).create(java.util.Map.of(
`)
            createItems.map((it: any, i: number) => {
              const comma = i < createItems.length - 1 ? ',' : ''
              Content(`    "${it.name}", ${scalaLit(it.type, 'example_' + it.name)}${comma}  // ${canonToType(it.type, target.name)}
`)
            })
            Content(`), null)
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
              return `    "${it.name}", ${scalaLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)}${comma}\n`
            }).join('')
            Content(`\`\`\`scala
val result = client.${accessor}(null).update(java.util.Map.of(
${updateLines}), null)
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data(newdata*) -> Object\`

Get or set the entity data.

#### \`matchArgs(newmatch*) -> Object\`

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

      Content(`\`\`\`scala
val feature = new java.util.LinkedHashMap[String, Object]()
`)
      activeFeatures.map((f: any) => {
        Content(`feature.put("${f.name}", java.util.Map.of("active", true))
`)
      })
      Content(`val options = new java.util.LinkedHashMap[String, Object]()
options.put("feature", feature)
val client = new ${SDK}(options)
\`\`\`

`)
    }

  })
})


export {
  ReadmeRef
}
