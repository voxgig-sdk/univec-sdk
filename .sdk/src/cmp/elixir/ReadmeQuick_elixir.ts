
import { cmp, Content, isAuthActive, envName, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { elixirLit } from './utility_elixir'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { ctx$: { model } } = props

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain, an active
  // load op, and a required non-id load param to demonstrate (the parent key).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `${Name}.new(H.deep(%{"apikey" => System.get_env("${envName(model)}_APIKEY")}))`
    : `${Name}.new()`

  Content(`### 1. Create a client

\`\`\`elixir
alias ${Name}.Helpers, as: H

sdk = ${ctor}
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const eVar = exampleEntity.name
    const opnames = entityOps(exampleEntity)
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list/2\` returns a list value node and raises on error.

\`\`\`elixir
try do
  ${eVar} = ${Name}.${eVar}(sdk)
  records = ${Name}.Entity.${eName}.list(${eVar})
  IO.inspect(records)
rescue
  err -> IO.puts("list failed: " <> inspect(err))
end
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = nestedEntity.name

      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `"${it.name}" => ${elixirLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load/2\` returns the bare record and raises on error.

\`\`\`elixir
try do
  ${neVar} = ${Name}.${neVar}(sdk)
  record = ${Name}.Entity.${neName}.load(${neVar}, H.deep(%{${neMatch.join(', ')}}))
  IO.inspect(record)
rescue
  err -> IO.puts("load failed: " <> inspect(err))
end
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `H.deep(%{${loadRequired.map((it: any) =>
          `"${it.name}" => ${elixirLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(', ')}})`
        : 'H.deep(%{})'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load/2\` returns the bare record and raises on error.

\`\`\`elixir
try do
  ${eVar} = ${Name}.${eVar}(sdk)
  record = ${Name}.Entity.${eName}.load(${eVar}, ${loadArg})
  IO.inspect(record)
rescue
  err -> IO.puts("load failed: " <> inspect(err))
end
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
      return chosen.map((it: any) => `"${it.name}" => ${elixirLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    const idValueFor = (opname: string): string => (null != dataIdF && opnames.includes('create'))
      ? `Voxgig.Struct.getprop(created, "${dataIdF}")`
      : elixirLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`elixir
${eVar} = ${Name}.${eVar}(sdk)

`)
      if (opnames.includes('create')) {
        Content(`# Create — returns the bare created record
created = ${Name}.Entity.${eName}.create(${eVar}, H.deep(%{${examplePairs('create').join(', ')}}))

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`"${idF}" => ${idValueFor('update')}`] : []).concat(examplePairs('update'))
        Content(`# Update
${Name}.Entity.${eName}.update(${eVar}, H.deep(%{${updatePairs.join(', ')}}))

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `"${it.name}" => ${idValueFor('remove')}`
            : `"${it.name}" => ${elixirLit(it.type, 'example_' + it.name)}`)
        Content(`# Remove
${Name}.Entity.${eName}.remove(${eVar}${removePairs.length ? `, H.deep(%{${removePairs.join(', ')}})` : ''})
`)
      }
      Content(`\`\`\`

`)
    }
  }
})


export {
  ReadmeQuick
}
