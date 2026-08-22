
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


// A type-correct OCaml `value` literal for a param: numeric/boolean/array/
// object params render a typed literal; strings render the quoted placeholder.
function ocamlLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '(Num 1.)'
  if ('BOOLEAN' === k) return '(Bool true)'
  if ('ARRAY' === k) return '(empty_list ())'
  if ('OBJECT' === k) return '(empty_map ())'
  return `(Str "${placeholder}")`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `Sdk_client.make (jo [("apikey", Str (Sys.getenv "${envName(model)}_APIKEY"))])`
    : `Sdk_client.make0 ()`

  Content(`\`\`\`ocaml
open Voxgig_struct
open Sdk_helpers

let () =
  let client = ${ctor} in
`)

  if (exampleEntity) {
    const fn = ocamlVarName(exampleEntity.name)
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes no match argument.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`  (* List all ${fn} records (one ENTITY per record; raises on error) *)
  let ${fn}s = (Sdk_client.${fn} client Noval).e_list (empty_map ()) Noval in
  List.iter (fun e -> print_endline (stringify (e.e_data_get ()))) ${fn}s;
`)
    }

    if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `jo [${loadItems.map((it: any) =>
          `("${it.name}", ${ocamlLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join('; ')}]`
        : 'Noval'
      Content(`  (* Load a specific ${fn} (returns the ENTITY; raises on error) *)
  let ${fn} = (Sdk_client.${fn} client Noval).e_load (${loadArg}) Noval in
  print_endline (stringify (${fn}.e_data_get ()))
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
