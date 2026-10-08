
import { cmp, each, Content, canonToType, canonKey, entityIdField, opRequestShape, opNeedsAction, javaMap, javaMapOf } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { scalaVarName, scalaListMatch, scalaLit } from './utility_scala'


// Type names come from the shared canonToType 'scala' column (single source of truth).

// Operation method spelling for Scala: camelCase methods over the loose object
// model. The op descriptions are language-agnostic.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load(match, null)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list(null, null)',    desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create(data, null)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'update(data, null)',  desc: 'Update an existing entity.' },
  patch:  { method: 'patch(data, null)',   desc: 'Change part of an existing entity.' },
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
    // An op that needs an action has no plain call to show.
    const callable = opnames.filter((o: string) => !opNeedsAction(entity.op[o]))
    const fields = Object.values(entity.fields || {})
    const idF = entityIdField(entity)
    // Sanitise the local variable name — a camelCased Scala keyword gets a
    // trailing underscore (scalaVarName) so the snippet compiles.
    const eVar = scalaVarName(entity.name)
    const accessor = scalaVarName(entity.name)

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
        const desc = field.sh || ''
        Content(`| \`${field.n}\` | \`${canonToType(field.t, target.name)}\` | ${desc} |
`)
      })

      Content(`
`)
    }

    if (callable.includes('load')) {
      // The id key plus every REQUIRED match key (parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? javaMapOf(loadItems.map((it: any) =>
          `"${it.name}", ${scalaLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}`), 'java.util.')
        : 'null'
      Content(`#### Example: Load

\`\`\`scala
val ${eVar} = client.${accessor}(null).load(${loadArg}, null)
\`\`\`

`)
    }

    if (callable.includes('list')) {
      Content(`#### Example: List

\`\`\`scala
val ${eVar}List = client.${accessor}(null).list(${scalaListMatch(entity)}, null)
\`\`\`

`)
    }

    if (callable.includes('create')) {
      // Members come from the SAME shape the runtime validates
      // (opRequestShape): every required member must appear — including a
      // required id and parent keys like page_id — with a real literal.
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      const createMap = javaMap(createItems.length, 'java.util.')
      Content(`#### Example: Create

\`\`\`scala
val ${eVar} = client.${accessor}(null).create(${createMap.open}
`)
      createItems.map((it: any, i: number) => {
        const comma = i < createItems.length - 1 ? ',' : ''
        Content(`    ${createMap.pair(`"${it.name}", ${scalaLit(it.type, 'example_' + it.name)}`)}${comma}  // ${canonToType(it.type, target.name)}
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
