
import { cmp, each, Content, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cIdent, cVarName } from './utility_c'


// Canonical type sentinel -> a C type name for the field/param tables.
function cType(type: any): string {
  const k = canonKey(type)
  if ('STRING' === k) return 'char*'
  if ('INTEGER' === k) return 'int64_t'
  if ('NUMBER' === k) return 'double'
  if ('BOOLEAN' === k) return 'bool'
  if ('ARRAY' === k) return 'voxgig_value* (list)'
  if ('OBJECT' === k) return 'voxgig_value* (map)'
  return 'voxgig_value*'
}


// A type-correct C expression constructing a voxgig struct Value.
function cLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'v_num(1)'
  if ('BOOLEAN' === k) return 'v_bool(true)'
  if ('ARRAY' === k) return 'v_list()'
  if ('OBJECT' === k) return 'v_map()'
  return `v_str("${placeholder}")`
}


// cmap(...) for a set of pairs, or NULL when empty.
function cmapExpr(pairs: string[]): string {
  return pairs.length ? `cmap(${pairs.length}, ${pairs.join(', ')})` : 'NULL'
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const ident = cIdent(model)
  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)

  const OP_SIGNATURES: Record<string, { sig: string, desc: string }> = {
    load: {
      sig: 'vt->load(Entity* e, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err)',
      desc: 'Load a single entity matching the given criteria. Returns the entity data and sets `*err` on failure.',
    },
    list: {
      sig: 'vt->list(Entity* e, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err)',
      desc: 'List entities matching the given criteria. The match is optional — pass `NULL` to list all records. Returns a List.',
    },
    create: {
      sig: 'vt->create(Entity* e, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err)',
      desc: 'Create a new entity with the given data. Returns the created entity data and sets `*err` on failure.',
    },
    update: {
      sig: 'vt->update(Entity* e, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err)',
      desc: 'Update an existing entity. The data must include the entity id. Returns the updated entity data.',
    },
    remove: {
      sig: 'vt->remove(Entity* e, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err)',
      desc: 'Remove the entity matching the given criteria. Sets `*err` on failure.',
    },
  }


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${Name}SDK

### Constructor

`)

    Content(`\`\`\`c
#include "core/api.h"

${Name}SDK* client = ${ident}_sdk_new(options);
\`\`\`

Create a new SDK client instance. \`options\` is a \`voxgig_value*\` map
(\`NULL\` for none).

**Parameters (\`options\` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
${isAuthActive(model) ? '| `apikey` | `string` | API key for authentication. |\n' : ''}| \`base\` | \`string\` | Base URL for API requests. |
| \`prefix\` | \`string\` | URL prefix appended after base. |
| \`suffix\` | \`string\` | URL suffix appended after path. |
| \`headers\` | \`map\` | Custom headers for all requests. |
| \`feature\` | \`map\` | Feature configuration. |
| \`system\` | \`map\` | System overrides. |

`)


    Content(`
### Test Constructor

`)

    Content(`#### \`${Name}SDK* test_sdk(voxgig_value* testopts, voxgig_value* sdkopts)\`

Create a test client with mock features active. Both arguments may be
\`NULL\`.

\`\`\`c
${Name}SDK* client = test_sdk(NULL, NULL);
\`\`\`

`)


    Content(`
### Entity Accessors

`)


    // Entity accessor functions
    publishedEntities.map((ent: any) => {
      Content(`#### \`Entity* ${ident}_${cVarName(ent.name)}(${Name}SDK* client, voxgig_value* entopts)\`

Create a new \`${ent.Name}\` entity instance. Pass \`NULL\` for no initial
options.

`)
    })


    Content(`#### \`voxgig_value* sdk_direct(${Name}SDK* client, voxgig_value* fetchargs, PNError** err)\`

Make a direct HTTP request to any API endpoint. Returns a result map with
\`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape
hatch never sets \`*err\` for a non-2xx response — branch on
\`getp(result, "ok")\`.

**Parameters (\`fetchargs\` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| \`path\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`string\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`map\` | Path parameter values. |
| \`query\` | \`map\` | Query string parameters. |
| \`headers\` | \`map\` | Request headers (merged with defaults). |
| \`body\` | \`any\` | Request body (maps are JSON-serialized). |

#### \`voxgig_value* sdk_prepare(${Name}SDK* client, voxgig_value* fetchargs, PNError** err)\`

Prepare a fetch definition without sending. Returns the fetchdef and sets
\`*err\` on failure.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      const idF = entityIdField(ent)
      const evar = cVarName(ent.name)
      const acc = `${ident}_${evar}`

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
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
          Content(`| \`${field.name}\` | \`${cType(field.type)}\` | ${req} | ${desc} |
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
            const arg = cmapExpr(matchItems.map((it: any) =>
              `"${it.name}", ${cLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)}`))
            Content(`\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* result = ${evar}->vt->${opname}(${evar}, ${arg}, NULL, &err);
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* results = ${evar}->vt->list(${evar}, NULL, NULL, &err);
for (size_t i = 0; i < (size_t)voxgig_size(results); i++) {
    printf("%s\\n", voxgig_to_json(voxgig_getelem(results, v_int(i), NULL)));
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
`)
            if (0 === createItems.length) {
              Content(`voxgig_value* result = ${evar}->vt->create(${evar}, NULL, NULL, &err);
`)
            } else {
              Content(`voxgig_value* result = ${evar}->vt->create(${evar}, cmap(${createItems.length},
`)
              createItems.map((it: any, i: number) => {
                const comma = i < createItems.length - 1 ? ',' : ')'
                Content(`    "${it.name}", ${cLit(it.type, 'example_' + it.name)}${comma}  // ${cType(it.type)}
`)
              })
              Content(`, NULL, &err);
`)
            }
            Content(`\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updatePairs = updateItems.map((it: any) =>
              `"${it.name}", ${cLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)}`)
            Content(`\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* result = ${evar}->vt->update(${evar}, ${cmapExpr(updatePairs)}, NULL, &err);
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`voxgig_value* vt->data(Entity* e, voxgig_value* args)\`

Get the entity data. Pass a map to set it.

#### \`voxgig_value* vt->matchv(Entity* e, voxgig_value* args)\`

Get the entity match criteria. Pass a map to set it.

#### \`Entity* vt->make(Entity* e)\`

Create a new \`${ent.Name}\` entity instance with the same options.

#### \`const char* vt->get_name(Entity* e)\`

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

      Content(`\`\`\`c
${Name}SDK* client = ${ident}_sdk_new(cmap(1,
    "feature", cmap(${activeFeatures.length},
`)
      activeFeatures.map((f: any, i: number) => {
        const comma = i < activeFeatures.length - 1 ? ',' : ')'
        Content(`        "${f.name}", cmap(1, "active", v_bool(true))${comma}
`)
      })
      Content(`));
\`\`\`

`)
    }

  })
})


export {
  ReadmeRef
}
