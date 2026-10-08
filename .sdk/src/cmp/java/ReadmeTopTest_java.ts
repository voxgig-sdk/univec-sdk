
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape, requiredItems, javaMapOf } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { javaVarName, javaLit } from './utility_java'


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
    if (isMatchOp || ('list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length)) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request type, so the block stays honest.
      const items = (isMatchOp ? opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF) : requiredItems(exampleEntity, 'list'))
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? javaMapOf(items.map((it: any) =>
          `${JSON.stringify(it.name)}, ${isMatchOp && it.name === idF ? '"test01"' : javaLit(it.type)}`))
        : 'null'
    } else if ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = javaMapOf(chosen.map((it: any) =>
        `${JSON.stringify(it.name)}, ${javaLit(it.type)}`))
    }
    const eVar = javaVarName(exampleEntity.name)
    const accessor = javaVarName(exampleEntity.name)
    Content('list' === primaryOp
      ? `List<?> ${eVar}List = (List<?>) client.${accessor}(null).list(${arg}, null);
for (Object ${eVar}Item : ${eVar}List) {
    System.out.println(((SdkEntity) ${eVar}Item).data());
}
`
      : `SdkEntity ${eVar} = (SdkEntity) client.${accessor}(null).${primaryOp}(${arg}, null);
System.out.println(${eVar}.data());
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
