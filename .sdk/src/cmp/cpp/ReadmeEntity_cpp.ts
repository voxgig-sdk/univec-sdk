
import { cmp, each, Content, canonToType, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


// Type names come from the shared canonToType 'cpp' column (single source of truth).

// A type-correct C++ literal for a field's canonical type.
function cppLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value(1)'
  if ('BOOLEAN' === k) return 'Value(true)'
  if ('ARRAY' === k) return 'vlist()'
  if ('OBJECT' === k) return 'vmap()'
  return `Value("${placeholder}")`
}


// Operation method spellings for the C++ target: lowercase methods that take a
// request Value plus the ctrl Value, returning sdk::Value.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load(match, ctrl)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list(match, ctrl)',   desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create(data, ctrl)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'update(data, ctrl)',  desc: 'Update an existing entity.' },
  remove: { method: 'remove(match, ctrl)', desc: 'Remove the matching entity.' },
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
    // The client accessor is the entity's snake_case name (client->planet()).
    const acc = cppVarName(entity.name)
    const eVar = acc

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`auto ${eVar} = client->${acc}();\`

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
      // page_id) — the same shape the runtime resolves path params from.
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `vmap({${loadItems.map((it: any) =>
          `{"${it.name}", ${cppLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}}`).join(', ')}})`
        : 'Value::undef()'
      Content(`#### Example: Load

\`\`\`cpp
Value ${eVar} = client->${acc}()->load(${loadArg}, Value::undef());
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`cpp
Value ${eVar}s = client->${acc}()->list(Value::undef(), Value::undef());
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      // Members come from the SAME shape the runtime validates
      // (opRequestShape): every required member must appear.
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`cpp
Value ${eVar} = client->${acc}()->create(vmap({
`)
      createItems.map((it: any) => {
        Content(`    {"${it.name}", ${cppLit(it.type, 'example_' + it.name)}},  // ${canonToType(it.type, target.name)}
`)
      })
      Content(`}), Value::undef());
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
