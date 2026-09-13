
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


// A type-correct Haskell `Value` literal for a param.
function hsLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'VNum 1'
  if ('BOOLEAN' === k) return 'VBool True'
  if ('ARRAY' === k || 'OBJECT' === k) return 'VNoval'
  return `VStr "${placeholder}"`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)

  Content(`\`\`\`haskell
`)
  if (authActive) {
    Content(`import System.Environment (lookupEnv)
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..), emptyMap)
import SdkHelpers (jo)

main :: IO ()
main = do
  mkey <- lookupEnv "${envName(model)}_APIKEY"
  opts <- jo [("apikey", maybe VNoval VStr mkey)]
  sdk <- Sdk.newSdk opts
`)
  }
  else {
    Content(`import qualified SdkClient as Sdk
import VoxgigStruct (Value (..), emptyMap)
import SdkHelpers (jo)

main :: IO ()
main = do
  sdk <- Sdk.newSdk0
`)
  }

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eFn = hsVarName(exampleEntity.name)
    const opnames = Object.keys(exampleEntity.op || {})
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`
  -- List all ${eName.toLowerCase()}s (one ENTITY per record, raises on error)
  ent <- Sdk.${eFn} sdk VNoval
  match <- emptyMap
  ctrl <- emptyMap
  ${eFn}s <- Sdk.eList ent match ctrl
  mapM_ (\\en -> print =<< Sdk.eDataGet en) ${eFn}s
`)
    }

    if (opnames.includes('load')) {
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `[${loadItems.map((it: any) =>
          `("${it.name}", ${hsLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join(', ')}]`
        : '[]'
      Content(`
  -- Load a specific ${eName.toLowerCase()} (returns the ENTITY, raises on error)
  ent2 <- Sdk.${eFn} sdk VNoval
  m <- jo ${loadArg}
  ctrl2 <- emptyMap
  ${eFn} <- Sdk.eLoad ent2 m ctrl2
  print =<< Sdk.eDataGet ${eFn}
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
