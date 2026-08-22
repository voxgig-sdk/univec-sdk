
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


// A type-correct C++ literal for a field's canonical type.
function cppLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value(1)'
  if ('BOOLEAN' === k) return 'Value(true)'
  if ('ARRAY' === k) return 'vlist()'
  if ('OBJECT' === k) return 'vmap()'
  return 'Value("example")'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`cpp
auto client = ${model.const.Name}SDK::testSDK();
`)

  if (exampleEntity && primaryOp) {
    const acc = cppVarName(exampleEntity.name)
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'Value::undef()'
    if (isMatchOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `vmap({${items.map((it: any) =>
          `{"${it.name}", ${it.name === idF ? 'Value("test01")' : cppLit(it.type)}}`).join(', ')}})`
        : 'Value::undef()'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `vmap({${chosen.map((it: any) => `{"${it.name}", ${cppLit(it.type)}}`).join(', ')}})`
    }
    const eVar = acc + ('list' === primaryOp ? 's' : '')
    Content(`Value ${eVar} = client->${acc}()->${primaryOp}(${arg}, Value::undef());
std::cout << Struct::jsonify(${eVar}) << std::endl;
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
