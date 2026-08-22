
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { kotlinVarName, kotlinPackage } from './utility_kotlin'


// A type-correct Kotlin literal for a param: numeric/boolean/array/object
// params render a typed literal; strings render the quoted placeholder. The
// SDK's loose object model means all values live in MutableMap<String, Any?>.
function kotlinLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'listOf<Any?>()'
  if ('OBJECT' === k) return 'mapOf<String, Any?>()'
  return `"${placeholder}"`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)

  Content(`\`\`\`kotlin
import ${kotlinPackage(model)}.core.${SDK}

`)

  if (authActive) {
    Content(`val client = ${SDK}(mutableMapOf<String, Any?>(
    "apikey" to System.getenv("${envName(model)}_APIKEY"),
))

`)
  }
  else {
    Content(`val client = ${SDK}()

`)
  }

  if (exampleEntity) {
    // Sanitise the local variable name — an entity whose camelCased name is a
    // Kotlin keyword gets a trailing underscore (kotlinVarName) so the snippet
    // compiles.
    const eVar = kotlinVarName(exampleEntity.name)
    const accessor = kotlinVarName(exampleEntity.name)
    const eNameLower = nom(exampleEntity, 'Name').toLowerCase()
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes an empty match.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${eNameLower}s (returns Any?, an aggregate list; raises on error)
val ${eVar}List = client.${accessor}(null).list(null, null)
println(${eVar}List)
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
        ? `mutableMapOf<String, Any?>(${loadItems.map((it: any) =>
          `"${it.name}" to ${kotlinLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(', ')})`
        : 'null'
      Content(`
// Load a specific ${eNameLower} (returns the record, raises on error)
val ${eVar} = client.${accessor}(null).load(${loadArg}, null)
println(${eVar})
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
