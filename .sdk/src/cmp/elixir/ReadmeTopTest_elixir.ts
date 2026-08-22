
import { cmp, Content, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { elixirLit } from './utility_elixir'


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
    const eVar = exampleEntity.name
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = ''
    if (isMatchOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `H.deep(%{${items.map((it: any) =>
          `"${it.name}" => ${it.name === idF ? '"test01"' : elixirLit(it.type)}`).join(', ')}})`
        : 'H.deep(%{})'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `H.deep(%{${chosen.map((it: any) => `"${it.name}" => ${elixirLit(it.type)}`).join(', ')}})`
    } else {
      arg = 'H.deep(%{})'
    }
    const resVar = 'list' === primaryOp ? 'records' : 'record'
    Content(`${eVar} = ${Name}.${eVar}(sdk)
${resVar} = ${Name}.Entity.${eName}.${primaryOp}(${eVar}, ${arg})
IO.inspect(${resVar})
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
