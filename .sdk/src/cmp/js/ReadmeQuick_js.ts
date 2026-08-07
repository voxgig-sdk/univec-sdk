
import { cmp, each, Content, isAuthActive, packageName, envName, opRequestShape, entityIdField, entityOps, safeVarName, exampleVarName, jsKey } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { exampleValue } from './utility_js'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Find the first published entity for examples
  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const ctor = isAuthActive(model)
    ? `new ${model.const.Name}SDK({\n  apikey: process.env.${envName(model)}_APIKEY,\n})`
    : `new ${model.const.Name}SDK()`

  Content(`
### Create a Client

\`\`\`js
const { ${model.const.Name}SDK } = require('${packageName(model, target.name)}')

const client = ${ctor}
\`\`\`
`)


  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    // ACTIVE ops only — an inactive op generates no method, so an example
    // calling it would be wrong.
    const opnames = entityOps(exampleEntity)

    // Model-driven example fields, in parity with the ts target: derive the
    // create/update body from the op shape (opRequestShape) so the docs show
    // REAL writable fields, not a hardcoded field the entity may not have.
    // `idF` is the entity's id-like field name, or null when it has none —
    // then load/remove match on no argument and update omits the id.
    const idF = entityIdField(exampleEntity)
    // Variable-safe lowercase name (a `Delete` entity must not bind `delete`).
    const eVar = exampleVarName(exampleEntity.name, 'js')
    const exampleFields = (opname: string): string[] => {
      // ids are rendered separately as the match key for update/remove; a
      // REQUIRED id stays for create (dropping it makes the payload
      // incomplete).
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      // create needs ALL required fields for parity with the typed ts target;
      // update is a patch, so the required members plus a sample optional
      // field or two suffice.
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) =>
        `  ${jsKey(it.name)}: ${exampleValue(exampleEntity, exampleEntity.op[opname], it.name, 'example_' + it.name)},`)
    }

    // The full REQUIRED match for load/remove (id first, then parent path
    // params like page_id) — the same shape the runtime resolves path params
    // from, so the example always carries the keys the route needs.
    const matchArg = (opname: string): string => {
      const matchItems = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      return 0 < matchItems.length
        ? `{ ${matchItems.map((it: any) =>
          `${jsKey(it.name)}: ${exampleValue(exampleEntity, exampleEntity.op && exampleEntity.op[opname], it.name,
            it.name === idF ? exampleEntity.name + '_id' : 'example_' + it.name)}`).join(', ')} }`
        : ''
    }

    if (opnames.includes('load')) {
      Content(`
### Load ${article} ${eName}

\`\`\`js
const ${eVar} = await client.${eName}().load(${matchArg('load')})
console.log(${eVar})
\`\`\`
`)
    }

    if (opnames.includes('list')) {
      Content(`
### List ${eName} Records

\`\`\`js
const ${eVar}s = await client.${eName}().list()
for (const ${eVar} of ${eVar}s) {
  console.log(${eVar})
}
\`\`\`
`)
    }

    if (opnames.includes('create')) {
      const createLines = exampleFields('create')
      const createBody = createLines.length ? '\n' + createLines.join('\n') + '\n' : ''
      Content(`
### Create a ${eName}

\`\`\`js
const created = await client.${eName}().create({${createBody}})
console.log(created)
\`\`\`
`)
    }

    if (opnames.includes('update')) {
      const updateLines = (idF
        ? [`  ${idF}: ${exampleValue(exampleEntity, exampleEntity.op && exampleEntity.op.update, idF, exampleEntity.name + '_id')},`]
        : []).concat(exampleFields('update'))
      const updateBody = updateLines.length ? '\n' + updateLines.join('\n') + '\n' : ''
      Content(`
### Update a ${eName}

\`\`\`js
const updated = await client.${eName}().update({${updateBody}})
console.log(updated)
\`\`\`
`)
    }

    if (opnames.includes('remove')) {
      Content(`
### Remove a ${eName}

\`\`\`js
await client.${eName}().remove(${matchArg('remove')})
\`\`\`
`)
    }
  }


  Content(`
### Direct API Access

Use \`client.direct()\` to call any API endpoint directly:

\`\`\`js
const result = await client.direct({
  path: '/custom/endpoint/{id}',
  method: 'GET',
  params: { id: 'abc123' },
})

if (result.ok) {
  console.log(result.data)
}
\`\`\`

`)

})


export {
  ReadmeQuick
}
