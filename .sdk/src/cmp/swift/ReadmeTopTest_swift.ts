
import { cmp, Content, canonKey, canonScalarKey, entityIdField, pickExampleEntity, opRequestShape, requiredItems } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { swiftVarName, swiftString } from './utility_swift'


// A type-correct Swift `Value` literal for a field's canonical type.
function swiftLit(type: any): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return '.null'
  if ('INTEGER' === k) return '.int(1)'
  if ('NUMBER' === k) return '.double(1.0)'
  if ('BOOLEAN' === k) return '.bool(true)'
  if ('ARRAY' === k) return '.list([])'
  if ('OBJECT' === k) return '.map(VMap())'
  return '.string("example")'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`swift
let client = ${SDK}.testSDK(nil, nil)
`)

  if (exampleEntity && primaryOp) {
    const eName = exampleEntity.Name
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'nil'
    if (isMatchOp || ('list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length)) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request type, so the block stays honest.
      const items = (isMatchOp ? opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF) : requiredItems(exampleEntity, 'list'))
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `VMap([${items.map((it: any) =>
          `(${swiftString(it.name)}, ${isMatchOp && it.name === idF ? '.string("test01")' : swiftLit(it.type)})`).join(', ')}])`
        : 'nil'
    } else if ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `VMap([${chosen.map((it: any) =>
        `(${swiftString(it.name)}, ${swiftLit(it.type)})`).join(', ')}])`
    }
    const eVar = swiftVarName(exampleEntity.name)
    Content('list' === primaryOp
      ? `let ${eVar}List = try client.${eName}().list(${arg}, nil)
for ${eVar}Item in ${eVar}List.asList?.items ?? [] {
    if let ${eVar}Entity = ${eVar}Item.asNative as? Entity {
        print(${eVar}Entity.data())
    }
}
`
      : `let ${eVar} = try client.${eName}().${primaryOp}(${arg}, nil)
if let ${eVar}Entity = ${eVar}.asNative as? Entity {
    print(${eVar}Entity.data())
}
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
