
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


// A type-correct Haskell `Value` literal for a field's canonical type.
function hsLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'VNum 1'
  if ('BOOLEAN' === k) return 'VBool True'
  if ('ARRAY' === k || 'OBJECT' === k) return 'VNoval'
  return 'VStr "example"'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..), emptyMap)
import SdkHelpers (jo)

main :: IO ()
main = do
  sdk <- Sdk.testSdk0
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const eFn = hsVarName(exampleEntity.name)
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let argExpr = 'emptyMap'
    if (isMatchOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      argExpr = 0 < items.length
        ? `jo [${items.map((it: any) =>
          `("${it.name}", ${it.name === idF ? 'VStr "test01"' : hsLit(it.type)})`).join(', ')}]`
        : 'emptyMap'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      argExpr = `jo [${chosen.map((it: any) => `("${it.name}", ${hsLit(it.type)})`).join(', ')}]`
    }
    const opCap = 'e' + primaryOp.charAt(0).toUpperCase() + primaryOp.slice(1)
    const resVar = hsVarName(exampleEntity.name) + ('list' === primaryOp ? 's' : '')
    Content(`  ent <- Sdk.${eFn} sdk VNoval
  arg <- ${argExpr}
  ctrl <- emptyMap
  ${resVar} <- Sdk.${opCap} ent arg ctrl
  print ${resVar}
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
