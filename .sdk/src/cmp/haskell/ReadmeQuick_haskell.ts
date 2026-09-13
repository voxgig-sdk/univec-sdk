
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


// A type-correct Haskell `Value` literal for a param. List/object params fall
// back to VNoval (they cannot be built as a pure literal inside `jo`); scalars
// use the matching constructor.
function hsLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'VNum 1'
  if ('BOOLEAN' === k) return 'VBool True'
  if ('ARRAY' === k || 'OBJECT' === k) return 'VNoval'
  return `VStr "${placeholder}"`
}


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain
  // (relations.ancestors), an active load op, and a required non-id load
  // param to demonstrate (the parent key, e.g. page_id).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)

  Content(`### 1. Create a client

\`\`\`haskell
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
  Content(`\`\`\`

Entity operations raise on error (via \`Control.Exception.throwIO\`) and
return the bare result \`Value\`. Wrap a call in \`Control.Exception.try\`
to recover from failures.

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const eFn = hsVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null when it has none. `dataIdF` is the id on the RETURNED record's data
    // type.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`eList ent match ctrl\` resolves to one ENTITY per record and raises on
error. Read a record with \`eDataGet\`.

\`\`\`haskell
  ent <- Sdk.${eFn} sdk VNoval
  match <- emptyMap
  ctrl <- emptyMap
  ${eFn}s <- Sdk.eList ent match ctrl
  mapM_ (\\en -> print =<< Sdk.eDataGet en) ${eFn}s
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neFn = hsVarName(nestedEntity.name)

      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `("${it.name}", ${hsLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)})`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`eLoad\` resolves to the ENTITY and raises on error; \`eDataGet\` gives the
record.

\`\`\`haskell
  ${neFn}Ent <- Sdk.${neFn} sdk VNoval
  m <- jo [${neMatch.join(', ')}]
  ctrl2 <- emptyMap
  ${neFn} <- Sdk.eLoad ${neFn}Ent m ctrl2
  print =<< Sdk.eDataGet ${neFn}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `[${loadRequired.map((it: any) =>
          `("${it.name}", ${hsLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join(', ')}]`
        : '[]'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`eLoad ent match ctrl\` resolves to the ENTITY and raises on error;
\`eDataGet\` gives the record.

\`\`\`haskell
  ent2 <- Sdk.${eFn} sdk VNoval
  m <- jo ${loadArg}
  ctrl2 <- emptyMap
  ${eFn} <- Sdk.eLoad ent2 m ctrl2
  print =<< Sdk.eDataGet ${eFn}
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape so the docs reference REAL writable fields.
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `("${it.name}", ${hsLit(it.type, 'example_' + it.name)})`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    const idValueFor = (opname: string): string =>
      hsLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

`)
      if (opnames.includes('create')) {
        Content(`\`\`\`haskell
  createEnt <- Sdk.${eFn} sdk VNoval
  d <- jo [${examplePairs('create').join(', ')}]
  cctrl <- emptyMap
  created <- Sdk.eCreate createEnt d cctrl
  print =<< Sdk.eDataGet created
\`\`\`

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`("${idF}", ${idValueFor('update')})`] : []).concat(examplePairs('update'))
        Content(`\`\`\`haskell
  updateEnt <- Sdk.${eFn} sdk VNoval
  upd <- jo [${updatePairs.join(', ')}]
  uctrl <- emptyMap
  updated <- Sdk.eUpdate updateEnt upd uctrl
  print =<< Sdk.eDataGet updated
\`\`\`

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `("${it.name}", ${idValueFor('remove')})`
            : `("${it.name}", ${hsLit(it.type, 'example_' + it.name)})`)
        Content(`\`\`\`haskell
  removeEnt <- Sdk.${eFn} sdk VNoval
  rm <- jo [${removePairs.length ? removePairs.join(', ') : ''}]
  rctrl <- emptyMap
  -- Resolves to the entity, marked deleted; it keeps the data it held.
  removed <- Sdk.eRemove removeEnt rm rctrl
  print =<< readIORef (Sdk.eDeleted removed)
\`\`\`

`)
      }
    }
  }
})


export {
  ReadmeQuick
}
