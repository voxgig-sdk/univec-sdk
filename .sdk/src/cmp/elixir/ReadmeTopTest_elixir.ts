
import { cmp, Content, entityIdField, pickExampleEntity, opRequestShape, elixirAccessor, entityCollection, exampleVarName, requiredItems } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { elixirLit, elixirString } from './utility_elixir'


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { ctx$: { model } } = props

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`elixir
alias ${Name}.Helpers, as: H

sdk = ${Name}.test()
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = exampleVarName(exampleEntity.name, 'elixir')
    const eCall = elixirAccessor(exampleEntity, entityCollection(model))
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = ''
    if (isMatchOp || ('list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length)) {
      const items = (isMatchOp ? opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF) : requiredItems(exampleEntity, 'list'))
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `H.deep(%{${items.map((it: any) =>
          `${elixirString(it.name)} => ${isMatchOp && it.name === idF ? '"test01"' : elixirLit(it.type)}`).join(', ')}})`
        : 'H.deep(%{})'
    } else if ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `H.deep(%{${chosen.map((it: any) => `${elixirString(it.name)} => ${elixirLit(it.type)}`).join(', ')}})`
    } else {
      arg = 'H.deep(%{})'
    }
    Content(`${eVar} = ${Name}.${eCall}(sdk)
${'list' === primaryOp
  ? `${eVar}s = ${Name}.Entity.${eName}.list(${eVar}, ${arg})
for i <- 0..(Voxgig.Struct.size(${eVar}s) - 1)//1 do
  IO.puts(Voxgig.Struct.jsonify(${Name}.Entity.${eName}.data_get(Voxgig.Struct.getelem(${eVar}s, i))))
end`
  : `${eVar} = ${Name}.Entity.${eName}.${primaryOp}(${eVar}, ${arg})
IO.puts(Voxgig.Struct.jsonify(${Name}.Entity.${eName}.data_get(${eVar})))`}
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
