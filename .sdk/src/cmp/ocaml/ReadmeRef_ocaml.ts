
import { cmp, each, Content, canonKey, canonScalarKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'
import { ReadmeRefFeatures } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


// A type-correct OCaml `value` literal. Strings render the quoted placeholder.
function ocamlLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '(Num 1.)'
  if ('BOOLEAN' === k) return '(Bool true)'
  if ('ARRAY' === k) return '(empty_list ())'
  if ('OBJECT' === k) return '(empty_map ())'
  return `(Str "${placeholder}")`
}


// The logical OCaml type of a field's canonical type (every field is carried
// inside the dynamic `value` variant).
function ocamlType(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return 'int'
  if ('NUMBER' === k) return 'float'
  if ('BOOLEAN' === k) return 'bool'
  if ('STRING' === k) return 'string'
  if ('ARRAY' === k) return 'value list'
  if ('OBJECT' === k) return 'value map'
  return 'value'
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'e_load reqmatch ctrl : entity_obj',
    returns: 'the entity',
    desc: 'Load a single entity matching the given criteria. Resolves to the ENTITY (read the record with `e_data_get`) and raises on error.',
  },
  list: {
    sig: 'e_list reqmatch ctrl : entity_obj list',
    returns: 'one entity per record',
    desc: 'List entities matching the given criteria. The match is optional \u2014 pass `(empty_map ())` to list all records. Resolves to one ENTITY per record and raises on error.',
  },
  create: {
    sig: 'e_create reqdata ctrl : entity_obj',
    returns: 'the created entity',
    desc: 'Create a new entity with the given data. Resolves to the ENTITY (read the record with `e_data_get`) and raises on error.',
  },
  update: {
    sig: 'e_update reqdata ctrl : entity_obj',
    returns: 'the updated entity',
    desc: 'Update an existing entity. The data must include the entity `id`. Resolves to the ENTITY (read the record with `e_data_get`) and raises on error.',
  },
  remove: {
    sig: 'e_remove reqmatch ctrl : entity_obj',
    returns: 'the removed entity',
    desc: 'Remove the entity matching the given criteria. Resolves to the ENTITY, marked deleted (`e_deleted`); it keeps the data it held. Raises on error.',
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


## Sdk_client

### Constructor

`)

    Content(`\`\`\`ocaml
open Voxgig_struct
open Sdk_helpers

let client = Sdk_client.make options
\`\`\`

Create a new SDK client instance from a \`value\` options map. Use
\`Sdk_client.make0 ()\` for defaults.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`options\` | \`value\` | SDK configuration options (a Map). |
${isAuthActive(model) ? '| `apikey` | `string` | API key for authentication. |\n' : ''}| \`base\` | \`string\` | Base URL for API requests. |
| \`prefix\` | \`string\` | URL prefix appended after base. |
| \`suffix\` | \`string\` | URL suffix appended after path. |
| \`headers\` | \`map\` | Custom headers for all requests. |
| \`feature\` | \`map\` | Feature configuration. |
| \`system\` | \`map\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Static constructors

`)

    Content(`#### \`Sdk_client.test testopts sdkopts\`

Create a test client with mock features active. Both arguments may be \`Noval\`
(\`Sdk_client.test ()\` uses defaults, \`Sdk_client.test_with\` takes explicit
options).

\`\`\`ocaml
let client = Sdk_client.test ()
\`\`\`

`)


    Content(`
### Instance functions

`)


    // Entity accessor functions
    publishedEntities.map((ent: any) => {
      const fn = ocamlVarName(ent.name)
      Content(`#### \`Sdk_client.${fn} client entopts : entity_obj\`

Create a \`${ent.Name}\` entity accessor. Pass \`Noval\` for no initial options.

`)
    })


    Content(`#### \`Sdk_client.direct client fetchargs : value\`

Make a direct HTTP request to any API endpoint. Returns a result \`value\` map
with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This
escape hatch never raises — branch on \`getp result "ok"\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`path\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`string\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`map\` | Path parameter values. |
| \`query\` | \`map\` | Query string parameters. |
| \`headers\` | \`map\` | Request headers (merged with defaults). |
| \`body\` | \`value\` | Request body (Maps are JSON-serialized). |

**Returns:** a result \`value\` map.

#### \`Sdk_client.prepare client fetchargs : value\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and raises
on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      const idF = entityIdField(ent)
      const fn = ocamlVarName(ent.name)

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`ocaml
let ${fn} = Sdk_client.${fn} client Noval
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
          Content(`| \`${field.name}\` | \`${ocamlType(field.type)}\` | ${req} | ${desc} |
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
              ? `jo [${matchItems.map((it: any) =>
                `("${it.name}", ${ocamlLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)})`).join('; ')}]`
              : 'Noval'
            Content(`\`\`\`ocaml
let result = (Sdk_client.${fn} client Noval).${'load' === opname ? 'e_load' : 'e_remove'} (${arg}) Noval
let result_data = result.e_data_get ()
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`ocaml
(* One ENTITY per record; the record is reached with e_data_get. *)
let results = (Sdk_client.${fn} client Noval).e_list (empty_map ()) Noval in
List.iter (fun e -> print_endline (stringify (e.e_data_get ()))) results
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`ocaml
let result = (Sdk_client.${fn} client Noval).e_create (jo [
`)
            createItems.map((it: any) => {
              Content(`    ("${it.name}", ${ocamlLit(it.type, 'example_' + it.name)});  (* ${ocamlType(it.type)} *)
`)
            })
            Content(`]) Noval
let result_data = result.e_data_get ()
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `    ("${it.name}", ${ocamlLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)});\n`).join('')
            Content(`\`\`\`ocaml
let result = (Sdk_client.${fn} client Noval).e_update (jo [
${updateLines}    (* Fields to update *)
]) Noval
let result_data = result.e_data_get ()
\`\`\`

`)
          }
        })
      }


      // Common fields
      Content(`### Common Fields

#### \`e_data_get : unit -> value\`

Get the entity data.

#### \`e_data_set : value -> unit\`

Set the entity data.

#### \`e_match_get : unit -> value\`

Get the entity match criteria.

#### \`e_match_set : value -> unit\`

Set the entity match criteria.

#### \`e_make : unit -> entity_obj\`

Create a new \`${ent.Name}\` entity accessor with the same options.

#### \`e_name : string\`

The entity name.

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

      Content(`\`\`\`ocaml
let client = Sdk_client.make (jo [
    ("feature", jo [
`)
      activeFeatures.map((f: any) => {
        Content(`        ("${f.name}", jo [("active", Bool true)]);
`)
      })
      Content(`    ]);
])
\`\`\`

`)
      // The shared feature reference: options, defaults, usage and the
      // considerations. Model facts, identical in every target, so they are
      // written once in cmp/ReadmeRefFeatures.ts rather than here.
      ReadmeRefFeatures({ target })
    }

  })
})




export {
  ReadmeRef
}
