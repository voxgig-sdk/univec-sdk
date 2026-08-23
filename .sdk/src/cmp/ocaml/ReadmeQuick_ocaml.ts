
import { cmp, Content, isAuthActive, envName, canonKey, canonScalarKey, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain, an active load
  // op, and a required non-id load param to demonstrate (the parent key).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `Sdk_client.make (jo [("apikey", Str (Sys.getenv "${envName(model)}_APIKEY"))])`
    : `Sdk_client.make0 ()`

  Content(`### 1. Create a client

\`\`\`ocaml
open Voxgig_struct
open Sdk_helpers

let client = ${ctor}
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const fn = ocamlVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field, or null.
    // `dataIdF` is the id on the RETURNED record's data type.
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    // A type-correct OCaml `value` literal for a param.
    const ocamlLit = (type: any, placeholder: string = 'example'): string => {
      const k = canonScalarKey(type)
      if ('INTEGER' === k || 'NUMBER' === k) return '(Num 1.)'
      if ('BOOLEAN' === k) return '(Bool true)'
      if ('ARRAY' === k) return '(empty_list ())'
      if ('OBJECT' === k) return '(empty_map ())'
      return `(Str "${placeholder}")`
    }

    if (opnames.includes('list')) {
      Content(`### 2. List ${fn} records

\`e_list\` resolves to one ENTITY per record and raises on error. Read a
record with \`e_data_get\`.

\`\`\`ocaml
(try
   let ${fn}s = (Sdk_client.${fn} client Noval).e_list (empty_map ()) Noval in
   List.iter (fun e -> print_endline (stringify (e.e_data_get ()))) ${fn}s
 with Sdk_error.E err -> Printf.eprintf "list failed: %s\\n" (Sdk_error.message err))
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neFn = ocamlVarName(nestedEntity.name)

      // Model-driven match: every REQUIRED load-match key. Parent keys first,
      // the entity's own id last.
      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `("${it.name}", ${ocamlLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)})`)

      Content(`### 3. Load ${neArticle} ${neFn}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`e_load\` resolves to the ENTITY and raises on error; \`e_data_get\` gives the
record.

\`\`\`ocaml
(try
   let ${neFn} = (Sdk_client.${neFn} client Noval).e_load (jo [${neMatch.join('; ')}]) Noval in
   print_endline (stringify (${neFn}.e_data_get ()))
 with Sdk_error.E err -> Printf.eprintf "load failed: %s\\n" (Sdk_error.message err))
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `jo [${loadRequired.map((it: any) =>
          `("${it.name}", ${ocamlLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join('; ')}]`
        : 'Noval'

      Content(`### 3. Load ${article} ${fn}

\`e_load\` resolves to the ENTITY and raises on error; \`e_data_get\` gives the
record.

\`\`\`ocaml
(try
   let ${fn} = (Sdk_client.${fn} client Noval).e_load (${loadArg}) Noval in
   print_endline (stringify (${fn}.e_data_get ()))
 with Sdk_error.E err -> Printf.eprintf "load failed: %s\\n" (Sdk_error.message err))
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape so the docs reference REAL writable fields.
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `("${it.name}", ${ocamlLit(it.type, 'example_' + it.name)})`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    const idValueFor = (opname: string): string => (null != dataIdF && opnames.includes('create'))
      ? `(getp created "${dataIdF}")`
      : ocamlLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`ocaml
`)
      if (opnames.includes('create')) {
        Content(`(* Create — resolves to the ENTITY; e_data_get gives the record *)
let created = (Sdk_client.${fn} client Noval).e_create (jo [${examplePairs('create').join('; ')}]) Noval in
print_endline (stringify (created.e_data_get ()));

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`("${idF}", ${idValueFor('update')})`] : []).concat(examplePairs('update'))
        Content(`(* Update *)
ignore ((Sdk_client.${fn} client Noval).e_update (jo [${updatePairs.join('; ')}]) Noval);

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `("${it.name}", ${idValueFor('remove')})`
            : `("${it.name}", ${ocamlLit(it.type, 'example_' + it.name)})`)
        Content(`(* Remove — resolves to the entity, marked deleted; it keeps its data *)
let removed = (Sdk_client.${fn} client Noval).e_remove (${removePairs.length ? `jo [${removePairs.join('; ')}]` : 'Noval'}) Noval in
Printf.printf "deleted: %b\\n" removed.e_deleted
`)
      }
      Content(`\`\`\`

`)
    }
  }
})


export {
  ReadmeQuick
}
