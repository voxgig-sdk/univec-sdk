
import { cmp, each, Content, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


// A type-correct Haskell `Value` literal for a field's canonical type.
function hsLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'VNum 1'
  if ('BOOLEAN' === k) return 'VBool True'
  if ('ARRAY' === k || 'OBJECT' === k) return 'VNoval'
  return `VStr "${placeholder}"`
}


// A readable Haskell type name for a field's canonical type. The runtime
// carries every field as a dynamic `Value`; this documents the logical type.
function hsType(type: any): string {
  const k = canonKey(type)
  if ('STRING' === k) return 'String'
  if ('INTEGER' === k) return 'Int'
  if ('NUMBER' === k) return 'Double'
  if ('BOOLEAN' === k) return 'Bool'
  if ('ARRAY' === k) return '[Value]'
  return 'Value'
}


const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'eLoad ent match ctrl',   desc: 'Load a single entity by match criteria. Resolves to the entity.' },
  list:   { method: 'eList ent match ctrl',   desc: 'List entities, optionally matching the given criteria. Resolves to one entity per record.' },
  create: { method: 'eCreate ent data ctrl',  desc: 'Create a new entity with the given data. Resolves to the entity.' },
  update: { method: 'eUpdate ent data ctrl',  desc: 'Update an existing entity. Resolves to the entity.' },
  remove: { method: 'eRemove ent match ctrl', desc: 'Remove the matching entity. Resolves to the entity, marked deleted.' },
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
    const eFn = hsVarName(entity.name)

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`${eFn} <- Sdk.${eFn} sdk VNoval\`

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
        Content(`| \`${field.name}\` | \`${hsType(field.type)}\` | ${desc} |
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
        ? `[${loadItems.map((it: any) =>
          `("${it.name}", ${hsLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)})`).join(', ')}]`
        : '[]'
      Content(`#### Example: Load

\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  match <- jo ${loadArg}
  ctrl <- emptyMap
  ${eFn} <- Sdk.eLoad ent match ctrl
  -- The op resolves to the ENTITY; the record is inside it.
  ${eFn}Data <- Sdk.eDataGet ${eFn}
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  match <- emptyMap
  ctrl <- emptyMap
  -- One ENTITY per record.
  ${eFn}s <- Sdk.eList ent match ctrl
  ${eFn}Datas <- mapM Sdk.eDataGet ${eFn}s
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  d <- jo
    [`)
      createItems.map((it: any, i: number) => {
        const bracket = 0 === i ? ' ' : ', '
        Content(`${bracket}("${it.name}", ${hsLit(it.type, 'example_' + it.name)})   -- ${hsType(it.type)}
    `)
      })
      Content(`]
  ctrl <- emptyMap
  ${eFn} <- Sdk.eCreate ent d ctrl
  ${eFn}Data <- Sdk.eDataGet ${eFn}
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
