import {
  Content,
  File,
  cmp,
  entitySpecMap,
  optionSpec,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import {
  cljStringChunks,
} from './utility_clojure'


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  const chunks = (json: string) =>
    cljStringChunks(json).map((c: string) => JSON.stringify(c)).join('\n       ')

  File({ name: 'schema.clj' }, () => {
    Content(`;; ${model.const.Name} ${target.Name} SDK: generated schemas. Do not edit.
;;
;; Generated from the model: main.kit.optspec and each feature's
;; config.options for the option spec; entity fields{}.type for the entity
;; specs. Parsed by sdk.core — see the note in Schema_clojure.ts for why the
;; parse cannot live here.
(ns sdk.schema)

(def optspec-data
  (str ${chunks(JSON.stringify(optspec))}))

(def entityspec-data
  (str ${chunks(JSON.stringify(entityspec))}))
`)
  })
})


export {
  Schema
}
