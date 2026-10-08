
import { cmp, Content, canonKey, canonScalarKey, entityIdField, pickExampleEntity, opRequestShape, requiredItems } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName, cppEscape } from './utility_cpp'


// A type-correct C++ literal for a field's canonical type.
function cppLit(type: any): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'Value(nullptr)'
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
    if (isMatchOp || ('list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length)) {
      const items = (isMatchOp ? opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF) : requiredItems(exampleEntity, 'list'))
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `vmap({${items.map((it: any) =>
          `{"${cppEscape(it.name)}", ${isMatchOp && it.name === idF ? 'Value("test01")' : cppLit(it.type)}}`).join(', ')}})`
        : 'Value::undef()'
    } else if ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `vmap({${chosen.map((it: any) => `{"${cppEscape(it.name)}", ${cppLit(it.type)}}`).join(', ')}})`
    }
    if ('list' === primaryOp) {
      Content(`for (const auto& ${acc} : client->${acc}()->list(${arg}, Value::undef())) {
  std::cout << Struct::jsonify(${acc}->data()) << std::endl;
}
`)
    }
    else {
      Content(`SdkEntityPtr ${acc} = client->${acc}()->${primaryOp}(${arg}, Value::undef());
std::cout << Struct::jsonify(${acc}->data()) << std::endl;
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
