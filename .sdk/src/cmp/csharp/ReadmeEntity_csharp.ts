
import { cmp, each, Content, canonToType, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { csVarName } from './utility_csharp'


// Type names come from the shared canonToType 'csharp' column (single source of truth).

// A type-correct, JSON-serialisable C# literal for a field's canonical type.
function csLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'new List<object?>()'
  if ('OBJECT' === k) return 'new Dictionary<string, object?>()'
  return `"${placeholder}"`
}


// Operation method spelling for C#: PascalCase methods over the loose object
// model. The op descriptions are language-agnostic.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'Load(match)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'List(null)',    desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'Create(data)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'Update(data)',  desc: 'Update an existing entity.' },
  remove: { method: 'Remove(match)', desc: 'Remove the matching entity.' },
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
    // Sanitise the local variable name — a camelCased C# keyword gets a
    // trailing underscore (csVarName) so the snippet compiles.
    const eVar = csVarName(entity.name)

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`var ${eVar} = client.${entity.Name}();\`

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
        ? `new Dictionary<string, object?> {${loadItems.map((it: any) =>
          ` ["${it.name}"] = ${csLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}`).join(',')} }`
        : 'null'
      Content(`#### Example: Load

\`\`\`csharp
var ${eVar} = client.${entity.Name}().Load(${loadArg});
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`csharp
var ${eVar}List = client.${entity.Name}().List(null);
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

\`\`\`csharp
var ${eVar} = client.${entity.Name}().Create(new Dictionary<string, object?>
{
`)
      createItems.map((it: any) => {
        Content(`    ["${it.name}"] = ${csLit(it.type, 'example_' + it.name)},  // ${canonToType(it.type, target.name)}
`)
      })
      Content(`});
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
