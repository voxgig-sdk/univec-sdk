
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { crateIdent, rustVarName } from './utility_rust'


// A type-correct rust expression constructing a voxgig struct Value for a
// field's canonical type.
function rustLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value::Num(1.0)'
  if ('BOOLEAN' === k) return 'Value::Bool(true)'
  if ('ARRAY' === k) return 'Value::empty_list()'
  if ('OBJECT' === k) return 'Value::empty_map()'
  return 'Value::str("example")'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const rustcrate = crateIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`rust
use ${rustcrate}::{jo, test_sdk, Value};

let client = test_sdk(Value::Noval, Value::Noval);
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const method = rustVarName(exampleEntity.name)
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'Value::Noval'
    if (isMatchOp) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request match.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `jo(vec![${items.map((it: any) =>
          `("${it.name}", ${it.name === idF ? 'Value::str("test01")' : rustLit(it.type)})`).join(', ')}])`
        : 'Value::Noval'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = 0 < chosen.length
        ? `jo(vec![${chosen.map((it: any) => `("${it.name}", ${rustLit(it.type)})`).join(', ')}])`
        : 'Value::empty_map()'
    }
    const eVar = rustVarName(exampleEntity.name) + ('list' === primaryOp ? 's' : '')
    Content(`let ${eVar} = client.${method}(Value::Noval).${primaryOp}(${arg}, Value::Noval).unwrap();
println!("{:?}", ${eVar});
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
