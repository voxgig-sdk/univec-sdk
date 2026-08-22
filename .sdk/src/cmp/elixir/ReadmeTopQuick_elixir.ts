
import { cmp, Content, isAuthActive, envName, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { elixirLit } from './utility_elixir'


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { ctx$: { model } } = props

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `${Name}.new(H.deep(%{"apikey" => System.get_env("${envName(model)}_APIKEY")}))`
    : `${Name}.new()`

  Content(`\`\`\`elixir
alias ${Name}.Helpers, as: H

sdk = ${ctor}

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = exampleEntity.name
    const opnames = Object.keys(exampleEntity.op || {})
    const idF = entityIdField(exampleEntity)

    Content(`${eVar} = ${Name}.${eVar}(sdk)
`)

    if (opnames.includes('list')) {
      Content(`
# List all ${eName.toLowerCase()} records (raises on error)
records = ${Name}.Entity.${eName}.list(${eVar})
IO.inspect(records)
`)
    }

    if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      // No required match keys (a singleton endpoint like /current) means no
      // second argument at all — `load(ent, )` is a syntax error, and
      // reqmatch defaults to nil, so load/1 is the correct call.
      const loadArgs = 0 < loadItems.length
        ? `${eVar}, H.deep(%{${loadItems.map((it: any) =>
          `"${it.name}" => ${elixirLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(', ')}})`
        : eVar
      Content(`
# Load a specific ${eName.toLowerCase()} (returns the record, raises on error)
record = ${Name}.Entity.${eName}.load(${loadArgs})
IO.inspect(record)
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
