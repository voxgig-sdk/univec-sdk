
import { cmp, each, Content, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


// A type-correct Clojure literal for a field's canonical type. The create
// example builds a real struct map, so array/object render as (vs/jt)/(vs/jm).
function cljLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '(vs/jt)'
  if ('OBJECT' === k) return '(vs/jm)'
  return `"${placeholder}"`
}


// A descriptive Clojure-ish type name for a field's canonical type. Clojure is
// dynamically typed, so these are documentation hints, not static types.
function cljType(type: any): string {
  const k = canonKey(type)
  if ('STRING' === k) return 'string'
  if ('INTEGER' === k) return 'long'
  if ('NUMBER' === k) return 'double'
  if ('BOOLEAN' === k) return 'boolean'
  if ('ARRAY' === k) return 'vector'
  if ('OBJECT' === k) return 'map'
  return 'any'
}


// Operation descriptions are language-agnostic; the method spelling matches
// the generated Clojure entity fns: (op ent arg ctrl).
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: '(load ent match ctrl)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: '(list ent match ctrl)',   desc: 'List entities, optionally matching the given criteria.' },
  create: { method: '(create ent data ctrl)',  desc: 'Create a new entity with the given data.' },
  update: { method: '(update ent data ctrl)',  desc: 'Update an existing entity.' },
  remove: { method: '(remove ent match ctrl)', desc: 'Remove the matching entity.' },
}


const ReadmeEntity = cmp(function ReadmeEntity(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const publishedEntities = each(entity)
    .filter((entity: any) => entity.active !== false)

  if (0 === publishedEntities.length) {
    return
  }

  Content(`

## Entities

`)

  publishedEntities.map((entity: any) => {
    const opnames = Object.keys(entity.op || {})
    const fields = entity.fields || []
    // Model-driven id key: null when this entity has no id-like field.
    const idF = entityIdField(entity)
    const eLow = entity.name

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`(def ${eLow} (api/${eLow} client nil))\`

`)

    if (opnames.length > 0) {
      Content(`#### Operations

| Method | Description |
| --- | --- |
`)
      opnames.map((opname: string) => {
        const info = OP_DESC[opname]
        if (info) {
          Content(`| \`${info.method}\` | ${info.desc} |
`)
        }
      })

      Content(`
`)
    }

    if (fields.length > 0) {
      Content(`#### Fields

| Field | Type | Description |
| --- | --- | --- |
`)

      each(fields, (field: any) => {
        const desc = field.short || ''
        Content(`| \`${field.name}\` | \`${cljType(field.type)}\` | ${desc} |
`)
      })

      Content(`
`)
    }

    if (opnames.includes('load')) {
      // The id key plus every REQUIRED match key (parent path params like
      // page_id) — the same shape the runtime resolves path params from.
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `(vs/jm ${loadItems.map((it: any) =>
          `"${it.name}" ${cljLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}`).join(' ')})`
        : 'nil'
      Content(`#### Example: Load

\`\`\`clojure
(def ${eLow} (e-${eLow}/load (api/${eLow} client nil) ${loadArg} nil))
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`clojure
(def ${eLow}s (e-${eLow}/list (api/${eLow} client nil) nil nil))
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      // Members come from the SAME shape the runtime validates
      // (opRequestShape): every required member must appear.
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`clojure
(def ${eLow}
  (e-${eLow}/create (api/${eLow} client nil)
    (vs/jm
`)
      createItems.map((it: any) => {
        Content(`      "${it.name}" ${cljLit(it.type, 'example_' + it.name)}  ;; ${cljType(it.type)}
`)
      })
      Content(`      )
    nil))
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
