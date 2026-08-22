
import { cmp, each, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain, an active load
  // op, and a required non-id load param to demonstrate (the parent key).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `(api/make-sdk (vs/jm "apikey" (System/getenv "${envName(model)}_APIKEY")))`
    : `(api/make-sdk nil)`

  // A type-correct Clojure literal for a param.
  const cljLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonKey(type)
    if ('INTEGER' === k || 'NUMBER' === k) return '1'
    if ('BOOLEAN' === k) return 'true'
    if ('ARRAY' === k) return '(vs/jt)'
    if ('OBJECT' === k) return '(vs/jm)'
    return `"${placeholder}"`
  }

  // Requires for block 1: the api ns, struct, plus every entity namespace the
  // quickstart references.
  const requireLines = ["(require '[sdk.api :as api]"]
  if (exampleEntity) {
    requireLines.push(`         '[sdk.entity.${exampleEntity.name} :as e-${exampleEntity.name}]`)
  }
  if (nestedEntity && (!exampleEntity || nestedEntity.name !== exampleEntity.name)) {
    requireLines.push(`         '[sdk.entity.${nestedEntity.name} :as e-${nestedEntity.name}]`)
  }
  requireLines.push(`         '[voxgig.struct :as vs])`)

  Content(`### 1. Create a client

\`\`\`clojure
${requireLines.join('\n')}

(def client ${ctor})
\`\`\`

`)

  if (exampleEntity) {
    const eLow = exampleEntity.name
    const article = /^[aeiou]/i.test(eLow) ? 'an' : 'a'
    const opnames = entityOps(exampleEntity)
    // `idF` is the entity's id-like MATCH field; `dataIdF` is the id on the
    // RETURNED record's data type.
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eLow} records

\`list\` returns a vector of records (each a map) and raises on error —
iterate it directly.

\`\`\`clojure
(try
  (doseq [${eLow} (e-${eLow}/list (api/${eLow} client nil) nil nil)]
    (println ${eLow}))
  (catch Exception err
    (println "list failed:" (.getMessage err))))
\`\`\`

`)
    }

    if (nestedEntity) {
      const neLow = nestedEntity.name
      const neArticle = /^[aeiou]/i.test(neLow) ? 'an' : 'a'

      // Model-driven match: every REQUIRED load-match key. Parent keys first,
      // the entity's own id last.
      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `"${it.name}" ${cljLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`)

      Content(`### 3. Load ${neArticle} ${neLow}

${nestedEntity.Name} is nested under ${parentName}, so provide the
\`${parentParam}\`. \`load\` returns the bare record (a map) and raises on error.

\`\`\`clojure
(try
  (let [${neLow} (e-${neLow}/load (api/${neLow} client nil) (vs/jm ${neMatch.join(' ')}) nil)]
    (println ${neLow}))
  (catch Exception err
    (println "load failed:" (.getMessage err))))
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `(vs/jm ${loadRequired.map((it: any) =>
          `"${it.name}" ${cljLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(' ')})`
        : 'nil'

      Content(`### 3. Load ${article} ${eLow}

\`load\` returns the bare record (a map) and raises on error.

\`\`\`clojure
(try
  (let [${eLow} (e-${eLow}/load (api/${eLow} client nil) ${loadArg} nil)]
    (println ${eLow}))
  (catch Exception err
    (println "load failed:" (.getMessage err))))
\`\`\`

`)
    }

    // Model-driven example fields from the op shape (opRequestShape).
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `"${it.name}" ${cljLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    const idValueFor = (opname: string): string => (null != dataIdF && opnames.includes('create'))
      ? `(vs/getprop created "${dataIdF}")`
      : cljLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`clojure
`)
      if (opnames.includes('create')) {
        Content(`;; Create — returns the bare created record (a map)
(def created (e-${eLow}/create (api/${eLow} client nil) (vs/jm ${examplePairs('create').join(' ')}) nil))

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`"${idF}" ${idValueFor('update')}`] : []).concat(examplePairs('update'))
        const fromCreated = null != dataIdF && opnames.includes('create')
        Content(`;; Update${fromCreated ? " — the created record's id is a plain map key" : ''}
(e-${eLow}/update (api/${eLow} client nil) (vs/jm ${updatePairs.join(' ')}) nil)

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `"${it.name}" ${idValueFor('remove')}`
            : `"${it.name}" ${cljLit(it.type, 'example_' + it.name)}`)
        Content(`;; Remove
(e-${eLow}/remove (api/${eLow} client nil) ${removePairs.length ? `(vs/jm ${removePairs.join(' ')})` : 'nil'} nil)
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
