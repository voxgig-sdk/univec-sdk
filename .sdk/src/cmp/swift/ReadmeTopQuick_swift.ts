
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { swiftVarName } from './utility_swift'


// A type-correct Swift `Value` literal for a param: numeric/boolean/array/
// object params render a typed literal; strings render the quoted placeholder.
// The SDK's loose object model means every value is a `Value` inside a `VMap`.
function swiftLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '.int(1)'
  if ('NUMBER' === k) return '.double(1.0)'
  if ('BOOLEAN' === k) return '.bool(true)'
  if ('ARRAY' === k) return '.list([])'
  if ('OBJECT' === k) return '.map(VMap())'
  return `.string("${placeholder}")`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'
  const MODULE = model.const.Name + 'Sdk'

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)

  Content(`\`\`\`swift
import ${MODULE}

`)

  if (authActive) {
    Content(`let options = VMap()
options.entries["apikey"] = .string(
    ProcessInfo.processInfo.environment["${envName(model)}_APIKEY"] ?? "")
let client = ${SDK}(options)

`)
  }
  else {
    Content(`let client = ${SDK}()

`)
  }

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = swiftVarName(exampleEntity.name)
    const eNameLower = eName.toLowerCase()
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes an empty match.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${eNameLower}s (returns a Value list, throws on error)
let ${eVar}List = try client.${eName}().list(nil, nil)
for ${eVar} in ${eVar}List.asList?.items ?? [] {
    print(${eVar})
}
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
      const loadArg = 0 < loadItems.length
        ? `VMap([${loadItems.map((it: any) =>
          `("${it.name}", ${swiftLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join(', ')}])`
        : 'nil'
      Content(`
// Load a specific ${eNameLower} (returns the record, throws on error)
let ${eVar} = try client.${eName}().load(${loadArg}, nil)
print(${eVar})
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
