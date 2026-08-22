
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'


// A type-correct Clojure literal for a param: numeric/boolean/array/object
// params render a typed literal; strings render the quoted placeholder.
function cljLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '(vs/jt)'
  if ('OBJECT' === k) return '(vs/jm)'
  return `"${placeholder}"`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `(api/make-sdk (vs/jm "apikey" (System/getenv "${envName(model)}_APIKEY")))`
    : `(api/make-sdk nil)`

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eLow = exampleEntity.name

    Content(`\`\`\`clojure
(require '[sdk.api :as api]
         '[sdk.entity.${eLow} :as e-${eLow}]
         '[voxgig.struct :as vs])

(def client ${ctor})

`)

    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes no match argument.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`;; List all ${eLow}s (returns a vector, raises on error)
(doseq [${eLow} (e-${eLow}/list (api/${eLow} client nil) nil nil)]
  (println ${eLow}))
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
        ? `(vs/jm ${loadItems.map((it: any) =>
          `"${it.name}" ${cljLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(' ')})`
        : 'nil'
      Content(`
;; Load a specific ${eLow} (returns the record, raises on error)
(def ${eLow} (e-${eLow}/load (api/${eLow} client nil) ${loadArg} nil))
(println ${eLow})
`)
    }

    Content(`\`\`\`
`)
  }
  else {
    Content(`\`\`\`clojure
(require '[sdk.api :as api]
         '[voxgig.struct :as vs])

(def client ${ctor})
\`\`\`
`)
  }

})


export {
  ReadmeTopQuick
}
