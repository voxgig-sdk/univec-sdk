
import { cmp, Content, canonKey, canonScalarKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


// A type-correct OCaml `value` literal for a field's canonical type.
function ocamlLit(type: any): string {
  const k = canonScalarKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '(Num 1.)'
  if ('BOOLEAN' === k) return '(Bool true)'
  if ('ARRAY' === k) return '(empty_list ())'
  if ('OBJECT' === k) return '(empty_map ())'
  return '(Str "example")'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`ocaml
let () =
  let client = Sdk_client.test () in
`)

  if (exampleEntity && primaryOp) {
    const fn = ocamlVarName(exampleEntity.name)
    const idF = entityIdField(exampleEntity)
    const field =
      'load' === primaryOp ? 'e_load' :
        'list' === primaryOp ? 'e_list' :
          'create' === primaryOp ? 'e_create' :
            'update' === primaryOp ? 'e_update' : 'e_remove'
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'Noval'
    if ('list' === primaryOp) {
      arg = '(empty_map ())'
    } else if (isMatchOp) {
      // Every REQUIRED match key (id first).
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `(jo [${items.map((it: any) =>
          `("${it.name}", ${it.name === idF ? '(Str "test01")' : ocamlLit(it.type)})`).join('; ')}])`
        : '(empty_map ())'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `(jo [${chosen.map((it: any) => `("${it.name}", ${ocamlLit(it.type)})`).join('; ')}])`
    }
    // The op resolves to the ENTITY (list: one per record); the record is
    // reached with e_data_get.
    Content('list' === primaryOp
      ? `  let results = (Sdk_client.${fn} client Noval).${field} ${arg} Noval in
  List.iter (fun e -> print_endline (stringify (e.e_data_get ()))) results
`
      : `  let result = (Sdk_client.${fn} client Noval).${field} ${arg} Noval in
  print_endline (stringify (result.e_data_get ()))
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
