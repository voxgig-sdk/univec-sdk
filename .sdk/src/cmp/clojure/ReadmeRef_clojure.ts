
import { cmp, each, Content, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


// A type-correct Clojure literal for a field's canonical type.
function cljLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '(vs/jt)'
  if ('OBJECT' === k) return '(vs/jm)'
  return `"${placeholder}"`
}


// A descriptive Clojure-ish type name (documentation hint, not a static type).
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


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: '(load ent reqmatch ctrl) -> map',
    returns: 'the entity data',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and raises on error.',
  },
  list: {
    sig: '(list ent reqmatch ctrl) -> vector',
    returns: 'a vector of entities',
    desc: 'List entities matching the given criteria. The match is optional — call with `nil` to list all records. Returns a vector and raises on error.',
  },
  create: {
    sig: '(create ent reqdata ctrl) -> map',
    returns: 'the created entity data',
    desc: 'Create a new entity with the given data. Returns the created entity data and raises on error.',
  },
  update: {
    sig: '(update ent reqdata ctrl) -> map',
    returns: 'the updated entity data',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and raises on error.',
  },
  remove: {
    sig: '(remove ent reqmatch ctrl) -> map',
    returns: 'the removed entity data',
    desc: 'Remove the entity matching the given criteria. Raises on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## Client

### make-sdk

`)

    Content(`\`\`\`clojure
(require '[sdk.api :as api]
         '[voxgig.struct :as vs])

(def client (api/make-sdk options))
\`\`\`

Create a new SDK client instance. \`options\` is a \`voxgig.struct\` map.

**Options:**

| Key | Type | Description |
| --- | --- | --- |
${isAuthActive(model) ? '| `apikey` | `string` | API key for authentication. |\n' : ''}| \`base\` | \`string\` | Base URL for API requests. |
| \`prefix\` | \`string\` | URL prefix appended after base. |
| \`suffix\` | \`string\` | URL suffix appended after path. |
| \`headers\` | \`map\` | Custom headers for all requests. |
| \`feature\` | \`map\` | Feature configuration. |
| \`system\` | \`map\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Test client

`)

    Content(`#### \`(api/test-sdk testopts sdkopts)\`

Create a test client with mock features active. Both arguments may be \`nil\`.

\`\`\`clojure
(def client (api/test-sdk nil nil))
\`\`\`

`)


    Content(`
### Client functions

`)


    // Entity factory functions
    publishedEntities.map((ent: any) => {
      Content(`#### \`(api/${ent.name} client data)\`

Create a new \`${ent.Name}\` entity instance. Pass \`nil\` for no initial data.

`)
    })


    Content(`#### \`(api/options-map client) -> map\`

Return a deep copy of the current SDK options.

#### \`(api/get-utility client) -> utility\`

Return a copy of the SDK utility object.

#### \`(api/direct client fetchargs) -> map\`

Make a direct HTTP request to any API endpoint. Returns a result \`map\` with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape hatch never raises — branch on \`(vs/getprop result "ok")\`.

**Fetch args:**

| Key | Type | Description |
| --- | --- | --- |
| \`path\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`string\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`map\` | Path parameter values. |
| \`query\` | \`map\` | Query string parameters. |
| \`headers\` | \`map\` | Request headers (merged with defaults). |
| \`body\` | \`any\` | Request body (maps are JSON-serialized). |

**Returns:** a result \`map\`.

#### \`(api/prepare client fetchargs) -> map\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and raises on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      // Model-driven id key: null when this entity has no id-like field.
      const idF = entityIdField(ent)
      const eLow = ent.name

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`clojure
(require '[sdk.entity.${eLow} :as e-${eLow}])

(def ${eLow} (api/${eLow} client nil))
\`\`\`

`)


      // Field schema
      if (fields.length > 0) {
        Content(`### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
`)
        each(fields, (field: any) => {
          const req = field.req ? 'Yes' : 'No'
          const desc = field.short || ''
          Content(`| \`${field.name}\` | \`${cljType(field.type)}\` | ${req} | ${desc} |
`)
        })

        Content(`
`)

        // Field operations breakdown
        const hasFieldOps = fields.some((f: any) => f.op && Object.keys(f.op).length > 0)
        if (hasFieldOps) {
          const opcols = ['load', 'list', 'create', 'update', 'remove']
            .filter((op: string) => opnames.includes(op) && ent.op[op]?.active !== false)
          Content(`### Field Usage by Operation

| Field | ${opcols.join(' | ')} |
| --- | ${opcols.map(() => '---').join(' | ')} |
`)
          each(fields, (field: any) => {
            const fops = field.op || {}
            const cols = opcols.map((op: string) => {
              const fop = fops[op]
              if (null == fop) return '-'
              if (fop.active === false) return '-'
              return 'Yes'
            })
            Content(`| \`${field.name}\` | ${cols.join(' | ')} |
`)
          })

          Content(`
`)
        }
      }


      // Operation details
      if (opnames.length > 0) {
        Content(`### Operations

`)

        opnames.map((opname: string) => {
          const info = OP_SIGNATURES[opname]
          if (!info) return

          Content(`#### \`${info.sig}\`

${info.desc}

`)

          if ('load' === opname || 'remove' === opname) {
            const matchItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const arg = 0 < matchItems.length
              ? `(vs/jm ${matchItems.map((it: any) =>
                `"${it.name}" ${cljLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}`).join(' ')})`
              : 'nil'
            Content(`\`\`\`clojure
(def result (e-${eLow}/${opname} (api/${eLow} client nil) ${arg} nil))
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`clojure
(doseq [${eLow} (e-${eLow}/list (api/${eLow} client nil) nil nil)]
  (println ${eLow}))
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`clojure
(def result
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
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `      "${it.name}" ${cljLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)}\n`).join('')
            Content(`\`\`\`clojure
(def result
  (e-${eLow}/update (api/${eLow} client nil)
    (vs/jm
${updateLines}      ;; Fields to update
      )
    nil))
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Members

State accessors are stored on the entity map and called via keyword lookup.

#### \`((:data-get ent)) -> map\`

Get the entity data.

#### \`((:data-set ent) data)\`

Set the entity data.

#### \`((:match-get ent)) -> map\`

Get the entity match criteria.

#### \`((:match-set ent) match)\`

Set the entity match criteria.

#### \`((:make ent)) -> entity\`

Create a new \`${ent.Name}\` entity instance with the same options.

#### \`((:get-name ent)) -> string\`

Return the entity name.

`)
    })


    // Features section
    const activeFeatures = each(feature).filter((f: any) => f.active)
    if (activeFeatures.length > 0) {
      Content(`
---

## Features

| Feature | Version | Description |
| --- | --- | --- |
`)

      activeFeatures.map((f: any) => {
        Content(`| \`${f.name}\` | ${f.version || '0.0.1'} | ${f.title || ''} |
`)
      })

      Content(`

Features are activated via the \`feature\` option:

`)

      Content(`\`\`\`clojure
(def client
  (api/make-sdk
    (vs/jm "feature"
      (vs/jm
`)
      activeFeatures.map((f: any) => {
        Content(`        "${f.name}" (vs/jm "active" true)
`)
      })
      Content(`        ))))
\`\`\`

`)
    }

  })
})




export {
  ReadmeRef
}
