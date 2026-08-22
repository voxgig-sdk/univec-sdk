
import { cmp, each, Content, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cIdent, cVarName } from './utility_c'


// Canonical type sentinel -> a C type name for the field/param tables. The
// runtime is dynamic (every value is a voxgig_value*), so these are the
// documentary C primitive types the field carries.
function cType(type: any): string {
  const k = canonKey(type)
  if ('STRING' === k) return 'char*'
  if ('INTEGER' === k) return 'int64_t'
  if ('NUMBER' === k) return 'double'
  if ('BOOLEAN' === k) return 'bool'
  if ('ARRAY' === k) return 'voxgig_value* (list)'
  if ('OBJECT' === k) return 'voxgig_value* (map)'
  return 'voxgig_value*'
}


// A type-correct C expression constructing a voxgig struct Value.
function cLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'v_num(1)'
  if ('BOOLEAN' === k) return 'v_bool(true)'
  if ('ARRAY' === k) return 'v_list()'
  if ('OBJECT' === k) return 'v_map()'
  return `v_str("${placeholder}")`
}


// cmap(...) for a set of pairs, or NULL when empty.
function cmapExpr(pairs: string[]): string {
  return pairs.length ? `cmap(${pairs.length}, ${pairs.join(', ')})` : 'NULL'
}


// Operation vtable descriptions (language-agnostic wording, C signatures).
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'vt->load(e, reqmatch, ctrl, &err)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'vt->list(e, reqmatch, ctrl, &err)',   desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'vt->create(e, reqdata, ctrl, &err)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'vt->update(e, reqdata, ctrl, &err)',  desc: 'Update an existing entity.' },
  remove: { method: 'vt->remove(e, reqmatch, ctrl, &err)', desc: 'Remove the matching entity.' },
}


const ReadmeEntity = cmp(function ReadmeEntity(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const ident = cIdent(model)
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
    const evar = cVarName(entity.name)
    const acc = `${ident}_${evar}`

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`Entity* ${evar} = ${acc}(client, NULL);\`

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
        Content(`| \`${field.name}\` | \`${cType(field.type)}\` | ${desc} |
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
      const loadArg = cmapExpr(loadItems.map((it: any) =>
        `"${it.name}", ${cLit(it.type,
          it.name === idF ? entity.name + '_id' : it.name)}`))
      Content(`#### Example: Load

\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* ${evar}_rec = ${evar}->vt->load(${evar}, ${loadArg}, NULL, &err);
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* ${evar}s = ${evar}->vt->list(${evar}, NULL, NULL, &err);
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
`)
      if (0 === createItems.length) {
        Content(`voxgig_value* ${evar}_rec = ${evar}->vt->create(${evar}, NULL, NULL, &err);
`)
      } else {
        Content(`voxgig_value* ${evar}_rec = ${evar}->vt->create(${evar}, cmap(${createItems.length},
`)
        createItems.map((it: any, i: number) => {
          const comma = i < createItems.length - 1 ? ',' : ')'
          Content(`    "${it.name}", ${cLit(it.type, 'example_' + it.name)}${comma}  // ${cType(it.type)}
`)
        })
        Content(`, NULL, &err);
`)
      }
      Content(`\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
