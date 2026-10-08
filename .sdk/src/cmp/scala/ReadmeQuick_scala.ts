
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityOps, javaMapOf } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { scalaVarName, scalaPackage, scalaListMatch, scalaLit } from './utility_scala'


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

  if (authActive) {
    Content(`### 1. Create a client

\`\`\`scala
import ${scalaPackage(model)}.core.${SDK}
import ${scalaPackage(model)}.core.SdkEntity

val options = new java.util.LinkedHashMap[String, Object]()
options.put("apikey", System.getenv("${envName(model)}_APIKEY"))
val client = new ${SDK}(options)
\`\`\`

`)
  }
  else {
    Content(`### 1. Create a client

\`\`\`scala
import ${scalaPackage(model)}.core.${SDK}
import ${scalaPackage(model)}.core.SdkEntity

val client = new ${SDK}()
\`\`\`

`)
  }

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    // Sanitise the local variable name — a camelCased Scala keyword gets a
    // trailing underscore (scalaVarName) so the snippet compiles.
    const eVar = scalaVarName(exampleEntity.name)
    const accessor = scalaVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null when it has none.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list(null, null)\` returns a list of entities, one per record (as \`Object\`),
and raises on error; an entity's \`data()\` reads its record.

\`\`\`scala
try {
    val ${eVar}List = client.${accessor}(null).list(${scalaListMatch(exampleEntity)}, null).asInstanceOf[java.util.List[SdkEntity]]
    ${eVar}List.forEach(${eVar}Item => println(${eVar}Item.data()))
}
catch {
    case err: RuntimeException => println("list failed: " + err.getMessage)
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = scalaVarName(nestedEntity.name)
      const neAccessor = scalaVarName(nestedEntity.name)

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
        `"${it.name}", ${scalaLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the ENTITY — call data() for the record — and raises on error.

\`\`\`scala
try {
    val ${neVar} = client.${neAccessor}(null).load(${javaMapOf(neMatch, 'java.util.')}, null).asInstanceOf[SdkEntity]
    println(${neVar}.data())
}
catch {
    case err: RuntimeException => println("load failed: " + err.getMessage)
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
        ? javaMapOf(loadRequired.map((it: any) =>
          `"${it.name}", ${scalaLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`), 'java.util.')
        : 'null'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the ENTITY — call data() for the record — and raises on error.

\`\`\`scala
try {
    val ${eVar} = client.${accessor}(null).load(${loadArg}, null).asInstanceOf[SdkEntity]
    println(${eVar}.data())
}
catch {
    case err: RuntimeException => println("load failed: " + err.getMessage)
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
      return chosen.map((it: any) => `"${it.name}", ${scalaLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('patch') ||
      opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`scala
`)
      if (opnames.includes('create')) {
        Content(`// Create — returns the ENTITY (call data() for the record)
val created = client.${accessor}(null).create(${javaMapOf(examplePairs('create'), 'java.util.')}, null)

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`"${idF}", ${scalaLit(idParamType('update'), 'example_id')}`] : [])
          .concat(examplePairs('update'))
        Content(`// Update — supply the id in the match/data
client.${accessor}(null).update(${javaMapOf(updatePairs, 'java.util.')}, null)

`)
      }
      if (opnames.includes('patch')) {
        const patchPairs = (idF ? [`"${idF}", ${scalaLit(idParamType('patch'), 'example_id')}`] : [])
          .concat(examplePairs('patch'))
        Content(`// Patch — sends only the fields given
client.${accessor}(null).patch(${javaMapOf(patchPairs, 'java.util.')}, null)

`)
      }
      if (opnames.includes('remove')) {
        // Every REQUIRED remove-match key: the id plus parent keys like page_id.
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `"${it.name}", ${scalaLit(idParamType('remove'), 'example_id')}`
            : `"${it.name}", ${scalaLit(it.type, 'example_' + it.name)}`)
        Content(`// Remove
client.${accessor}(null).remove(${removePairs.length ? javaMapOf(removePairs, 'java.util.') : 'null'}, null)
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
