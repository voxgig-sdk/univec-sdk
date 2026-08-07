
import { cmp, Content, isAuthActive, packageName, envName, entityIdField, entityOps, opRequestShape, safeVarName, exampleVarName, jsKey } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { exampleValue } from './utility_js'


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const ctor = isAuthActive(model)
    ? `new ${model.const.Name}SDK({\n  apikey: process.env.${envName(model)}_APIKEY,\n})`
    : `new ${model.const.Name}SDK()`

  Content(`\`\`\`js
const { ${model.const.Name}SDK } = require('${packageName(model, target.name)}')

const client = ${ctor}

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = exampleVarName(eName.toLowerCase(), 'js')
    // ACTIVE ops only — an inactive op generates no method, so an example
    // calling it would be wrong.
    const opnames = entityOps(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${eName.toLowerCase()}s (returns an array)
const ${eVar}s = await client.${eName}().list()
for (const ${eVar} of ${eVar}s) {
  console.log(${eVar})
}
`)
    }

    // Find a nested entity for a more interesting example: one with a parent
    // chain (relations.ancestors), an active load op of its OWN, and a
    // required non-id load param to demonstrate (the parent key, e.g.
    // page_id).
    const nestedEntity = Object.values(entity).find((e: any) =>
      e.active !== false &&
      e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
      entityOps(e).includes('load') &&
      opRequestShape(e, 'load').items.some((it: any) =>
        !it.optional && it.name !== entityIdField(e))
    ) as any

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neVar = exampleVarName(neName.toLowerCase(), 'js')
      const loadOp = nestedEntity.op && nestedEntity.op.load

      // Every REQUIRED load-match key (parent keys like page_id first, the
      // entity's own id last) — the same shape the runtime resolves path
      // params from, so the example always works.
      const neIdF = entityIdField(nestedEntity)
      const neMatchLines = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === neIdF)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
        .map((it: any) =>
          `  ${jsKey(it.name)}: ${exampleValue(nestedEntity, loadOp, it.name,
            it.name === neIdF ? 'example_id' : 'example_' + it.name)},`)

      Content(`
// Load a specific ${neName.toLowerCase()} (returns the entity)
const ${neVar} = await client.${neName}().load({
${neMatchLines.join('\n')}
})
console.log(${neVar})
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
