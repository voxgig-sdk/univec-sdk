
import { cmp, each, Content, canonToType, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { rustVarName } from './utility_rust'


// Type names come from the shared canonToType 'rust' column (single source of truth).

// A type-correct rust expression constructing a voxgig struct Value.
function rustLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value::Num(1.0)'
  if ('BOOLEAN' === k) return 'Value::Bool(true)'
  if ('ARRAY' === k) return 'Value::empty_list()'
  if ('OBJECT' === k) return 'Value::empty_map()'
  return `Value::str("${placeholder}")`
}


// Operation method descriptions (language-agnostic wording, rust signatures).
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load(reqmatch, ctrl)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list(reqmatch, ctrl)',   desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create(reqdata, ctrl)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'update(reqdata, ctrl)',  desc: 'Update an existing entity.' },
  remove: { method: 'remove(reqmatch, ctrl)', desc: 'Remove the matching entity.' },
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
    const idF = entityIdField(entity)
    const eVar = rustVarName(entity.name)
    const method = rustVarName(entity.name)

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`let ${eVar} = client.${method}(Value::Noval);\`

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
        ? `jo(vec![${loadItems.map((it: any) =>
          `("${it.name}", ${rustLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)})`).join(', ')}])`
        : 'Value::Noval'
      Content(`#### Example: Load

\`\`\`rust
let ${eVar} = client.${method}(Value::Noval).load(${loadArg}, Value::Noval).unwrap();
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`rust
let ${eVar}s = client.${method}(Value::Noval).list(Value::Noval, Value::Noval).unwrap();
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`rust
let ${eVar} = client.${method}(Value::Noval).create(jo(vec![
`)
      createItems.map((it: any) => {
        Content(`    ("${it.name}", ${rustLit(it.type, 'example_' + it.name)}),  // ${canonToType(it.type, target.name)}
`)
      })
      Content(`]), Value::Noval).unwrap();
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
