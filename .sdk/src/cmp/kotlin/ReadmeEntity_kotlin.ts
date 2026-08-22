
import { cmp, each, Content, canonToType, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { kotlinVarName } from './utility_kotlin'


// Type names come from the shared canonToType 'kotlin' column (single source of truth).

// A type-correct Kotlin literal for a field's canonical type.
function kotlinLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'listOf<Any?>()'
  if ('OBJECT' === k) return 'mapOf<String, Any?>()'
  return `"${placeholder}"`
}


// Operation method spelling for Kotlin: camelCase methods over the loose
// object model. The op descriptions are language-agnostic.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load(match, null)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list(null, null)',    desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create(data, null)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'update(data, null)',  desc: 'Update an existing entity.' },
  remove: { method: 'remove(match, null)', desc: 'Remove the matching entity.' },
}


const ReadmeEntity = cmp(function ReadmeEntity(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const publishedEntities = each(entity)
    .filter((entity: any) => entity.active !== false)

  if (0 === publishedEntities.length) {
    return
  }

  Content(`

## Entities

`)

  publishedEntities.map((entity: any) => {
    const opnames = Object.keys(entity.op || {})
    const fields = entity.fields || []
    // Model-driven id key: null when this entity has no id-like field.
    const idF = entityIdField(entity)
    // Sanitise the local variable name — a camelCased Kotlin keyword gets a
    // trailing underscore (kotlinVarName) so the snippet compiles.
    const eVar = kotlinVarName(entity.name)
    const accessor = kotlinVarName(entity.name)

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`val ${eVar} = client.${accessor}(null)\`

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
      // The id key plus every REQUIRED match key (parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `mutableMapOf<String, Any?>(${loadItems.map((it: any) =>
          `"${it.name}" to ${kotlinLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}`).join(', ')})`
        : 'null'
      Content(`#### Example: Load

\`\`\`kotlin
val ${eVar} = client.${accessor}(null).load(${loadArg}, null)
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`kotlin
val ${eVar}List = client.${accessor}(null).list(null, null)
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      // Members come from the SAME shape the runtime validates
      // (opRequestShape): every required member must appear — including a
      // required id and parent keys like page_id — with a real literal.
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`kotlin
val ${eVar} = client.${accessor}(null).create(mutableMapOf<String, Any?>(
`)
      createItems.map((it: any, i: number) => {
        const comma = i < createItems.length - 1 ? ',' : ''
        Content(`    "${it.name}" to ${kotlinLit(it.type, 'example_' + it.name)}${comma}  // ${canonToType(it.type, target.name)}
`)
      })
      Content(`), null)
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
