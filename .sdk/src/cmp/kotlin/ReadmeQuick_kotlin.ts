
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { kotlinVarName, kotlinPackage } from './utility_kotlin'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

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

  // A type-correct Kotlin literal for a param — the loose object model means
  // all values live in a MutableMap<String, Any?>.
  const kotlinLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonKey(type)
    if ('INTEGER' === k) return '1L'
    if ('NUMBER' === k) return '1.0'
    if ('BOOLEAN' === k) return 'true'
    if ('ARRAY' === k) return 'listOf<Any?>()'
    if ('OBJECT' === k) return 'mapOf<String, Any?>()'
    return `"${placeholder}"`
  }

  if (authActive) {
    Content(`### 1. Create a client

\`\`\`kotlin
import ${kotlinPackage(model)}.core.${SDK}

val client = ${SDK}(mutableMapOf<String, Any?>(
    "apikey" to System.getenv("${envName(model)}_APIKEY"),
))
\`\`\`

`)
  }
  else {
    Content(`### 1. Create a client

\`\`\`kotlin
import ${kotlinPackage(model)}.core.${SDK}

val client = ${SDK}()
\`\`\`

`)
  }

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    // Sanitise the local variable name — a camelCased Kotlin keyword gets a
    // trailing underscore (kotlinVarName) so the snippet compiles.
    const eVar = kotlinVarName(exampleEntity.name)
    const accessor = kotlinVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null when it has none.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list(null, null)\` returns an aggregate list of records (as \`Any?\`, an
aggregate list) and raises on error.

\`\`\`kotlin
try {
    val ${eVar}List = client.${accessor}(null).list(null, null)
    println(${eVar}List)
}
catch (err: RuntimeException) {
    println("list failed: " + err.message)
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = kotlinVarName(nestedEntity.name)
      const neAccessor = kotlinVarName(nestedEntity.name)

      // Model-driven match: every REQUIRED load-match key. Parent keys (e.g.
      // page_id) first, the entity's own id last.
      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `"${it.name}" to ${kotlinLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the ENTITY — call data() for the record — and raises on error.

\`\`\`kotlin
try {
    val ${neVar} = client.${neAccessor}(null).load(mutableMapOf<String, Any?>(${neMatch.join(', ')}), null)
    println(${neVar})
}
catch (err: RuntimeException) {
    println("load failed: " + err.message)
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params).
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `mutableMapOf<String, Any?>(${loadRequired.map((it: any) =>
          `"${it.name}" to ${kotlinLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(', ')})`
        : 'null'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the ENTITY — call data() for the record — and raises on error.

\`\`\`kotlin
try {
    val ${eVar} = client.${accessor}(null).load(${loadArg}, null)
    println(${eVar})
}
catch (err: RuntimeException) {
    println("load failed: " + err.message)
}
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape (opRequestShape) so the docs reference REAL writable fields.
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `"${it.name}" to ${kotlinLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`kotlin
`)
      if (opnames.includes('create')) {
        Content(`// Create — returns the ENTITY (call data() for the record)
val created = client.${accessor}(null).create(mutableMapOf<String, Any?>(${examplePairs('create').join(', ')}), null)

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`"${idF}" to ${kotlinLit(idParamType('update'), 'example_id')}`] : [])
          .concat(examplePairs('update'))
        Content(`// Update — supply the id in the match/data
client.${accessor}(null).update(mutableMapOf<String, Any?>(${updatePairs.join(', ')}), null)

`)
      }
      if (opnames.includes('remove')) {
        // Every REQUIRED remove-match key: the id plus parent keys like page_id.
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `"${it.name}" to ${kotlinLit(idParamType('remove'), 'example_id')}`
            : `"${it.name}" to ${kotlinLit(it.type, 'example_' + it.name)}`)
        Content(`// Remove
client.${accessor}(null).remove(${removePairs.length ? `mutableMapOf<String, Any?>(${removePairs.join(', ')})` : 'null'}, null)
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
