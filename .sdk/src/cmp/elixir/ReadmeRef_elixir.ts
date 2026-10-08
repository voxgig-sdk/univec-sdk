
import { cmp, each, Content, canonToType, File, isAuthActive, entityIdField, opRequestShape , targetFeatures, opNeedsAction, bodyNote, elixirAccessor, entityCollection, exampleVarName } from '@voxgig/sdkgen'
import { ReadmeRefFeatures } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

// Type names come from the shared canonToType 'elixir' column (single source of truth).
import { elixirLit, elixirListArgs } from './utility_elixir'


const OP_SIGNATURES: Record<string, { sig: string, desc: string }> = {
  load: {
    sig: 'load(entity, reqmatch, ctrl \\\\ nil) :: entity',
    desc: 'Load a single entity matching the given criteria. Returns the entity, whose record `data_get/1` reads, and raises on error.',
  },
  list: {
    sig: 'list(entity, reqmatch \\\\ nil, ctrl \\\\ nil) :: list()',
    desc: 'List entities matching the given criteria. The match is optional — call `list(entity)` to list all records. Returns a list of entities, one per record, and raises on error.',
  },
  create: {
    sig: 'create(entity, reqdata, ctrl \\\\ nil) :: entity',
    desc: 'Create a new entity with the given data. Returns the created entity and raises on error.',
  },
  update: {
    sig: 'update(entity, reqdata, ctrl \\\\ nil) :: entity',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity and raises on error.',
  },
  patch: {
    sig: 'patch(entity, reqdata, ctrl \\\\ nil) :: entity',
    desc: 'Change part of an existing entity: only the fields given are sent. The data must include the entity `id`. Returns the patched entity and raises on error.',
  },
  remove: {
    sig: 'remove(entity, reqmatch, ctrl \\\\ nil) :: entity',
    desc: 'Remove the entity matching the given criteria. Returns the entity, marked as deleted, and raises on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = targetFeatures(model, target)

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
      Content(`#### \`${Name}.${elixirAccessor(ent, entityCollection(model))}(client, entopts \\\\ nil)\`

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
      const eVar = exampleVarName(ent.name, 'elixir')
      const eCall = elixirAccessor(ent, entityCollection(model))
      const opnames = Object.keys(ent.op || {})
      const fields = Object.values(ent.fields || {})
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
${eVar} = ${Name}.${eCall}(sdk)
\`\`\`

`)


      // Field schema
      if (fields.length > 0) {
        Content(`### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
`)
        each(fields, (field: any) => {
          const req = field.r ? 'Yes' : 'No'
          const desc = field.sh || ''
          Content(`| \`${field.n}\` | \`${canonToType(field.t, target.name)}\` | ${req} | ${desc} |
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

          if (opNeedsAction(ent.op[opname])) {
            return
          }

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
${eVar} = ${Name}.Entity.${EName}.${opname}(${eVar}, ${arg})
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`elixir
${eVar}s = ${Name}.Entity.${EName}.list(${eVar}${elixirListArgs(ent, Name)})
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`elixir
${eVar} = ${Name}.Entity.${EName}.create(${eVar}, ${Name}.Helpers.deep(%{
`)
            createItems.map((it: any) => {
              Content(`  "${it.name}" => ${elixirLit(it.type, 'example_' + it.name)},  # ${canonToType(it.type, target.name)}
`)
            })
            Content(`}))
\`\`\`

`)
          }
          else if ('update' === opname || 'patch' === opname) {
            const updateItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `  "${it.name}" => ${elixirLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)},\n`).join('')
            Content(`\`\`\`elixir
${eVar} = ${Name}.Entity.${EName}.${opname}(${eVar}, ${Name}.Helpers.deep(%{
${updateLines}  # ${'patch' === opname ? 'Only the fields to change' : 'Fields to update'}
}))
\`\`\`

`)
          }

          if ('create' === opname || 'update' === opname || 'patch' === opname) {
            const note = bodyNote(ent.op[opname], {
              values: 'a binary',
            })
            if ('' !== note) Content(note)
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
      ReadmeRefFeatures({ target })
    }

  })
})


export {
  ReadmeRef
}
