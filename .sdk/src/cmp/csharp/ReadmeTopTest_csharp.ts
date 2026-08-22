
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { csVarName } from './utility_csharp'


// A type-correct C# literal for a field's canonical type.
function csLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'new List<object?>()'
  if ('OBJECT' === k) return 'new Dictionary<string, object?>()'
  return '"example"'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`csharp
var client = ${model.const.Name}SDK.TestSDK(null, null);
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const idF = entityIdField(exampleEntity)
    const opMethod = primaryOp.charAt(0).toUpperCase() + primaryOp.slice(1)
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
        ? `new Dictionary<string, object?> {${items.map((it: any) =>
          ` ["${it.name}"] = ${it.name === idF ? '"test01"' : csLit(it.type)}`).join(',')} }`
        : 'null'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `new Dictionary<string, object?> {${chosen.map((it: any) =>
        ` ["${it.name}"] = ${csLit(it.type)}`).join(',')} }`
    }
    const eVar = csVarName(exampleEntity.name) + ('list' === primaryOp ? 'List' : '')
    Content(`var ${eVar} = client.${eName}().${opMethod}(${arg});
Console.WriteLine(${eVar});
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
