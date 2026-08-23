
import { cmp, Content, isAuthActive, envName, canonKey, canonScalarKey, opRequestShape, entityIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { swiftVarName } from './utility_swift'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'
  const MODULE = model.const.Name + 'Sdk'

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

  // A type-correct Swift `Value` literal for a param — the loose object model
  // means all values live in a `VMap` of `Value`.
  const swiftLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonScalarKey(type)
    if ('INTEGER' === k) return '.int(1)'
    if ('NUMBER' === k) return '.double(1.0)'
    if ('BOOLEAN' === k) return '.bool(true)'
    if ('ARRAY' === k) return '.list([])'
    if ('OBJECT' === k) return '.map(VMap())'
    return `.string("${placeholder}")`
  }

  if (authActive) {
    Content(`### 1. Create a client

\`\`\`swift
import ${MODULE}

let options = VMap()
options.entries["apikey"] = .string(
    ProcessInfo.processInfo.environment["${envName(model)}_APIKEY"] ?? "")
let client = ${SDK}(options)
\`\`\`

`)
  }
  else {
    Content(`### 1. Create a client

\`\`\`swift
import ${MODULE}

let client = ${SDK}()
\`\`\`

`)
  }

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const eVar = swiftVarName(exampleEntity.name)
    const accessor = exampleEntity.Name
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null when it has none.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list(nil, nil)\` returns a \`Value\` list of records and throws on error —
iterate its items.

\`\`\`swift
do {
    let ${eVar}List = try client.${accessor}().list(nil, nil)
    for ${eVar} in ${eVar}List.asList?.items ?? [] {
        print(${eVar})
    }
}
catch {
    print("list failed: \\(error)")
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = swiftVarName(nestedEntity.name)
      const neAccessor = nestedEntity.Name

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
        `("${it.name}", ${swiftLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)})`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the ENTITY — call data() for the record — and throws on error.

\`\`\`swift
do {
    let ${neVar} = try client.${neAccessor}().load(VMap([${neMatch.join(', ')}]), nil)
    print(${neVar})
}
catch {
    print("load failed: \\(error)")
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
        ? `VMap([${loadRequired.map((it: any) =>
          `("${it.name}", ${swiftLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join(', ')}])`
        : 'nil'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the ENTITY — call data() for the record — and throws on error.

\`\`\`swift
do {
    let ${eVar} = try client.${accessor}().load(${loadArg}, nil)
    print(${eVar})
}
catch {
    print("load failed: \\(error)")
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
      return chosen.map((it: any) => `("${it.name}", ${swiftLit(it.type, 'example_' + it.name)})`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`swift
`)
      if (opnames.includes('create')) {
        Content(`// Create — returns the ENTITY (call data() for the record)
let created = try client.${accessor}().create(VMap([${examplePairs('create').join(', ')}]), nil)

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`("${idF}", ${swiftLit(idParamType('update'), 'example_id')})`] : [])
          .concat(examplePairs('update'))
        Content(`// Update — supply the id in the match/data
_ = try client.${accessor}().update(VMap([${updatePairs.join(', ')}]), nil)

`)
      }
      if (opnames.includes('remove')) {
        // Every REQUIRED remove-match key: the id plus parent keys like page_id.
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `("${it.name}", ${swiftLit(idParamType('remove'), 'example_id')})`
            : `("${it.name}", ${swiftLit(it.type, 'example_' + it.name)})`)
        Content(`// Remove
_ = try client.${accessor}().remove(${removePairs.length ? `VMap([${removePairs.join(', ')}])` : 'nil'}, nil)
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
