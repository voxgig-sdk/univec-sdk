
import { cmp, Content, entityIdField, pickExampleEntity, opRequestShape, safeVarName, exampleVarName, jsKey } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { exampleValue } from './utility_js'


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity like Cloudsmith's `Abort`.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`js
const client = ${model.const.Name}SDK.test()
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    // A list() result is an array — name the variable accordingly.
    const eVar = exampleVarName(eName.toLowerCase(), 'js') +
      ('list' === primaryOp ? 's' : '')
    const primaryOpDef = exampleEntity.op && exampleEntity.op[primaryOp]
    const idF = entityIdField(exampleEntity)
    let arg = ''
    if ('load' === primaryOp || 'remove' === primaryOp) {
      // Every REQUIRED match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `{ ${items.map((it: any) =>
          `${jsKey(it.name)}: ${exampleValue(exampleEntity, primaryOpDef, it.name,
            it.name === idF ? 'test01' : 'example_' + it.name)}`).join(', ')} }`
        : ''
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `{ ${chosen.map((it: any) =>
        `${jsKey(it.name)}: ${exampleValue(exampleEntity, primaryOpDef, it.name, 'example_' + it.name)}`).join(', ')} }`
    }
    Content(`const ${eVar} = await client.${eName}().${primaryOp}(${arg})
// ${eVar} is ${'list' === primaryOp ? 'an array of bare entities' : 'a bare entity'} populated with mock data
console.log(${eVar})
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
