
import { cmp, each, Content, canonToType, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

// Type names come from the shared canonToType 'elixir' column (single source of truth).
import { elixirLit } from './utility_elixir'


const OP_SIGNATURES: Record<string, { sig: string, desc: string }> = {
  load: {
    sig: 'load(entity, reqmatch, ctrl \\\\ nil) :: map()',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and raises on error.',
  },
  list: {
    sig: 'list(entity, reqmatch \\\\ nil, ctrl \\\\ nil) :: list()',
    desc: 'List entities matching the given criteria. The match is optional — call `list(entity)` to list all records. Returns a list and raises on error.',
  },
  create: {
    sig: 'create(entity, reqdata, ctrl \\\\ nil) :: map()',
    desc: 'Create a new entity with the given data. Returns the created entity data and raises on error.',
  },
  update: {
    sig: 'update(entity, reqdata, ctrl \\\\ nil) :: map()',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and raises on error.',
  },
  remove: {
    sig: 'remove(entity, reqmatch, ctrl \\\\ nil) :: map()',
    desc: 'Remove the entity matching the given criteria. Raises on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${Name}

### Constructor

\`\`\`elixir
sdk = ${Name}.new(options)
\`\`\`

Create a new SDK client. \`options\` is a struct value node — build one from a
native map with \`${Name}.Helpers.deep/1\`.

**Options:**

| Name | Type | Description |
| --- | --- | --- |
${isAuthActive(model) ? '| `apikey` | `String.t()` | API key for authentication. |\n' : ''}| \`base\` | \`String.t()\` | Base URL for API requests. |
| \`prefix\` | \`String.t()\` | URL prefix appended after base. |
| \`suffix\` | \`String.t()\` | URL suffix appended after path. |
| \`headers\` | \`map()\` | Custom headers for all requests. |
| \`feature\` | \`map()\` | Feature configuration. |
| \`system\` | \`map()\` | System overrides (e.g. custom fetch). |


### Constructors

#### \`${Name}.test(testopts \\\\ nil, sdkopts \\\\ nil)\`

Create a test client with mock features active. Both arguments may be \`nil\`.

\`\`\`elixir
sdk = ${Name}.test()
\`\`\`


### Functions

`)


    // Entity factory functions
    publishedEntities.map((ent: any) => {
      Content(`#### \`${Name}.${ent.name}(client, entopts \\\\ nil)\`

Create a \`${Name}.Entity.${ent.Name}\` handle.

`)
    })


    Content(`#### \`options_map(client) :: map()\`

Return a deep copy of the current SDK options.

#### \`get_utility(client) :: map()\`

Return the SDK utility node.

#### \`direct(client, fetchargs) :: map()\`

Make a direct HTTP request to any API endpoint. Returns a result node with
\`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape
hatch never raises — branch on \`Voxgig.Struct.getprop(result, "ok")\`.

**fetchargs keys:**

| Key | Type | Description |
| --- | --- | --- |
| \`path\` | \`String.t()\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`String.t()\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`map()\` | Path parameter values. |
| \`query\` | \`map()\` | Query string parameters. |
| \`headers\` | \`map()\` | Request headers (merged with defaults). |
| \`body\` | \`any()\` | Request body (maps are JSON-serialized). |

#### \`prepare(client, fetchargs) :: map()\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and raises
on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const EName = ent.Name
      const eVar = ent.name
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      const idF = entityIdField(ent)

      Content(`
---

## ${Name}.Entity.${EName}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`elixir
${eVar} = ${Name}.${eVar}(sdk)
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
              ? `${Name}.Helpers.deep(%{${matchItems.map((it: any) =>
                `"${it.name}" => ${elixirLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}`).join(', ')}})`
              : `${Name}.Helpers.deep(%{})`
            Content(`\`\`\`elixir
record = ${Name}.Entity.${EName}.${opname}(${eVar}, ${arg})
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`elixir
records = ${Name}.Entity.${EName}.list(${eVar})
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`elixir
record = ${Name}.Entity.${EName}.create(${eVar}, ${Name}.Helpers.deep(%{
`)
            createItems.map((it: any) => {
              Content(`  "${it.name}" => ${elixirLit(it.type, 'example_' + it.name)},  # ${canonToType(it.type, target.name)}
`)
            })
            Content(`}))
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `  "${it.name}" => ${elixirLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)},\n`).join('')
            Content(`\`\`\`elixir
record = ${Name}.Entity.${EName}.update(${eVar}, ${Name}.Helpers.deep(%{
${updateLines}  # Fields to update
}))
\`\`\`

`)
          }
        })
      }


      // Common functions
      Content(`### Common Functions

#### \`data_get(entity) :: map()\`

Get the entity data.

#### \`data_set(entity, data)\`

Set the entity data.

#### \`match_get(entity) :: map()\`

Get the entity match criteria.

#### \`match_set(entity, match)\`

Set the entity match criteria.

#### \`make(entity) :: entity\`

Create a new \`${Name}.Entity.${EName}\` handle with the same options.

#### \`get_name(entity) :: String.t()\`

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

      Content(`\`\`\`elixir
sdk = ${Name}.new(${Name}.Helpers.deep(%{
  "feature" => %{
`)
      activeFeatures.map((f: any) => {
        Content(`    "${f.name}" => %{"active" => true},
`)
      })
      Content(`  }
}))
\`\`\`

`)
    }

  })
})


export {
  ReadmeRef
}
