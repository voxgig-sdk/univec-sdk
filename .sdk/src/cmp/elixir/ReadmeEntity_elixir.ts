
import { cmp, each, Content, canonToType, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

// Type names come from the shared canonToType 'elixir' column (single source of truth).
import { elixirLit } from './utility_elixir'


// Operation method spelling for the Elixir target: each op is a function on
// the entity's module taking the entity handle first. The descriptions are
// language-agnostic.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load(entity, match)',  desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list(entity)',         desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create(entity, data)', desc: 'Create a new entity with the given data.' },
  update: { method: 'update(entity, data)', desc: 'Update an existing entity.' },
  remove: { method: 'remove(entity, match)', desc: 'Remove the matching entity.' },
}


const ReadmeEntity = cmp(function ReadmeEntity(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)

  const publishedEntities = each(entity)
    .filter((entity: any) => entity.active !== false)

  if (0 === publishedEntities.length) {
    return
  }

  Content(`

## Entities

Every operation lives on the entity's \`${Name}.Entity.<Name>\` module and
takes an entity handle built from the client:

`)

  publishedEntities.map((entity: any) => {
    const EName = entity.Name
    const eVar = entity.name
    const opnames = Object.keys(entity.op || {})
    const fields = entity.fields || []
    const idF = entityIdField(entity)

    Content(`
### ${EName}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create a handle: \`${eVar} = ${Name}.${eVar}(sdk)\`

`)

    if (opnames.length > 0) {
      Content(`#### Operations

| Method | Description |
| --- | --- |
`)
      opnames.map((opname: string) => {
        const info = OP_DESC[opname]
        if (info) {
          Content(`| \`${info.method}\` | ${info.desc} |
`)
        }
      })

      Content(`
`)
    }

    if (fields.length > 0) {
      Content(`#### Fields

| Field | Type | Description |
| --- | --- | --- |
`)

      each(fields, (field: any) => {
        const desc = field.short || ''
        Content(`| \`${field.name}\` | \`${canonToType(field.type, target.name)}\` | ${desc} |
`)
      })

      Content(`
`)
    }

    if (opnames.includes('load')) {
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `${Name}.Helpers.deep(%{${loadItems.map((it: any) =>
          `"${it.name}" => ${elixirLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}`).join(', ')}})`
        : `${Name}.Helpers.deep(%{})`
      Content(`#### Example: Load

\`\`\`elixir
${eVar} = ${Name}.${eVar}(sdk)
record = ${Name}.Entity.${EName}.load(${eVar}, ${loadArg})
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`elixir
${eVar} = ${Name}.${eVar}(sdk)
records = ${Name}.Entity.${EName}.list(${eVar})
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      // Members come from the SAME shape the runtime validates
      // (opRequestShape): every required member must appear — with a real,
      // executable literal.
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`elixir
${eVar} = ${Name}.${eVar}(sdk)
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
  })
})


export {
  ReadmeEntity
}
