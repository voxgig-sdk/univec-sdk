
import { cmp, each, Content, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


// A type-correct OCaml `value` literal for a field's canonical type. Strings
// render the quoted placeholder.
function ocamlLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '(Num 1.)'
  if ('BOOLEAN' === k) return '(Bool true)'
  if ('ARRAY' === k) return '(empty_list ())'
  if ('OBJECT' === k) return '(empty_map ())'
  return `(Str "${placeholder}")`
}


// The logical OCaml type of a field's canonical type. The SDK carries every
// field inside the dynamic `value` variant, so this documents the underlying
// shape a caller reads out of the value.
function ocamlType(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return 'int'
  if ('NUMBER' === k) return 'float'
  if ('BOOLEAN' === k) return 'bool'
  if ('STRING' === k) return 'string'
  if ('ARRAY' === k) return 'value list'
  if ('OBJECT' === k) return 'value map'
  return 'value'
}


// The op accessor spelling on the entity_obj record, plus a language-agnostic
// description.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'e_load reqmatch ctrl',   desc: 'Load a single entity by match criteria. Resolves to the entity.' },
  list:   { method: 'e_list reqmatch ctrl',   desc: 'List entities, optionally matching the given criteria. Resolves to one entity per record.' },
  create: { method: 'e_create reqdata ctrl',  desc: 'Create a new entity with the given data. Resolves to the entity.' },
  update: { method: 'e_update reqdata ctrl',  desc: 'Update an existing entity. Resolves to the entity.' },
  remove: { method: 'e_remove reqmatch ctrl', desc: 'Remove the matching entity. Resolves to the entity, marked deleted.' },
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
    const fn = ocamlVarName(entity.name)

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`let ${fn} = Sdk_client.${fn} client Noval\`

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
        Content(`| \`${field.name}\` | \`${ocamlType(field.type)}\` | ${desc} |
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
        ? `jo [${loadItems.map((it: any) =>
          `("${it.name}", ${ocamlLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)})`).join('; ')}]`
        : 'Noval'
      Content(`#### Example: Load

\`\`\`ocaml
(* The op resolves to the ENTITY; the record is inside it. *)
let ${fn} = (Sdk_client.${fn} client Noval).e_load (${loadArg}) Noval
let ${fn}_data = ${fn}.e_data_get ()
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`ocaml
(* One ENTITY per record. *)
let ${fn}s = (Sdk_client.${fn} client Noval).e_list (empty_map ()) Noval
let ${fn}_datas = List.map (fun e -> e.e_data_get ()) ${fn}s
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`ocaml
let ${fn} = (Sdk_client.${fn} client Noval).e_create (jo [
`)
      createItems.map((it: any) => {
        Content(`    ("${it.name}", ${ocamlLit(it.type, 'example_' + it.name)});  (* ${ocamlType(it.type)} *)
`)
      })
      Content(`]) Noval
let ${fn}_data = ${fn}.e_data_get ()
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
