
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { kotlinVarName } from './utility_kotlin'


// A type-correct Kotlin literal for a field's canonical type.
function kotlinLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'listOf<Any?>()'
  if ('OBJECT' === k) return 'mapOf<String, Any?>()'
  return '"example"'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`kotlin
val client = ${SDK}.testSDK(null, null)
`)

  if (exampleEntity && primaryOp) {
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'null'
    if (isMatchOp) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request type, so the block stays honest.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `mutableMapOf<String, Any?>(${items.map((it: any) =>
          `"${it.name}" to ${it.name === idF ? '"test01"' : kotlinLit(it.type)}`).join(', ')})`
        : 'null'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `mutableMapOf<String, Any?>(${chosen.map((it: any) =>
        `"${it.name}" to ${kotlinLit(it.type)}`).join(', ')})`
    }
    const eVar = kotlinVarName(exampleEntity.name) + ('list' === primaryOp ? 'List' : '')
    const accessor = kotlinVarName(exampleEntity.name)
    Content(`val ${eVar} = client.${accessor}(null).${primaryOp}(${arg}, null)
println(${eVar})
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
