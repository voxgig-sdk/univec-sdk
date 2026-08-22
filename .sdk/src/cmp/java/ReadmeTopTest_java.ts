
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { javaVarName } from './utility_java'


// A type-correct Java literal for a field's canonical type.
function javaLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'List.of()'
  if ('OBJECT' === k) return 'Map.of()'
  return '"example"'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`java
${SDK} client = ${SDK}.testSDK(null, null);
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
        ? `Map.of(${items.map((it: any) =>
          `"${it.name}", ${it.name === idF ? '"test01"' : javaLit(it.type)}`).join(', ')})`
        : 'null'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `Map.of(${chosen.map((it: any) =>
        `"${it.name}", ${javaLit(it.type)}`).join(', ')})`
    }
    const eVar = javaVarName(exampleEntity.name) + ('list' === primaryOp ? 'List' : '')
    const accessor = javaVarName(exampleEntity.name)
    Content(`Object ${eVar} = client.${accessor}(null).${primaryOp}(${arg}, null);
System.out.println(${eVar});
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
