
import { cmp, Content, canonKey, canonScalarKey, entityIdField, pickExampleEntity, opRequestShape, requiredItems } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { csVarName, csStringLiteral } from './utility_csharp'


// A type-correct C# literal for a field's canonical type.
function csLit(type: any): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'null'
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
    if (isMatchOp || ('list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length)) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request type, so the block stays honest.
      const items = (isMatchOp ? opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF) : requiredItems(exampleEntity, 'list'))
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `new Dictionary<string, object?> {${items.map((it: any) =>
          ` [${csStringLiteral(it.name)}] = ${isMatchOp && it.name === idF ? '"test01"' : csLit(it.type)}`).join(',')} }`
        : 'null'
    } else if ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `new Dictionary<string, object?> {${chosen.map((it: any) =>
        ` [${csStringLiteral(it.name)}] = ${csLit(it.type)}`).join(',')} }`
    }
    const eVar = csVarName(exampleEntity.name)
    Content('list' === primaryOp
      ? `var ${eVar}List = (List<object?>)client.${eName}().List(${arg})!;
foreach (var ${eVar}Item in ${eVar}List)
{
    Console.WriteLine(StructUtils.Jsonify(((IEntity)${eVar}Item!).Data()));
}
`
      : `var ${eVar} = (IEntity)client.${eName}().${opMethod}(${arg})!;
Console.WriteLine(StructUtils.Jsonify(${eVar}.Data()));
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
