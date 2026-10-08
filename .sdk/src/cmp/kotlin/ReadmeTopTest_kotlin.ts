
import { cmp, Content, canonKey, canonScalarKey, entityIdField, pickExampleEntity, opRequestShape, requiredItems } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { kotlinVarName, kotlinString } from './utility_kotlin'


// A type-correct Kotlin literal for a field's canonical type.
function kotlinLit(type: any): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'null'
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
    if (isMatchOp || ('list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length)) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request type, so the block stays honest.
      const items = (isMatchOp ? opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF) : requiredItems(exampleEntity, 'list'))
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `mutableMapOf<String, Any?>(${items.map((it: any) =>
          `${kotlinString(it.name)} to ${isMatchOp && it.name === idF ? '"test01"' : kotlinLit(it.type)}`).join(', ')})`
        : 'null'
    } else if ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `mutableMapOf<String, Any?>(${chosen.map((it: any) =>
        `${kotlinString(it.name)} to ${kotlinLit(it.type)}`).join(', ')})`
    }
    const eVar = kotlinVarName(exampleEntity.name)
    const accessor = kotlinVarName(exampleEntity.name)
    Content('list' === primaryOp
      ? `val ${eVar}List = client.${accessor}(null).list(${arg}, null) as List<*>
for (${eVar}Item in ${eVar}List) {
    println((${eVar}Item as SdkEntity).data())
}
`
      : `val ${eVar} = client.${accessor}(null).${primaryOp}(${arg}, null) as SdkEntity
println(${eVar}.data())
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
