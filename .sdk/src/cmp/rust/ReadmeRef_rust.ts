
import { cmp, each, Content, canonToType, canonKey, canonScalarKey, File, isAuthActive, entityIdField, opRequestShape , targetFeatures, opNeedsAction, bodyNote } from '@voxgig/sdkgen'
import { ReadmeRefFeatures } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { crateIdent, rustVarName, rustMethodName, rustListMatch } from './utility_rust'


// Type names come from the shared canonToType 'rust' column (single source of truth).

// A type-correct rust expression constructing a voxgig struct Value.
function rustLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'Value::Null'
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value::Num(1.0)'
  if ('BOOLEAN' === k) return 'Value::Bool(true)'
  if ('ARRAY' === k) return 'Value::empty_list()'
  if ('OBJECT' === k) return 'Value::empty_map()'
  return `Value::str("${placeholder}")`
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const rustcrate = crateIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = targetFeatures(model, target)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)

  const errType = `${model.const.Name}Error`
  const OP_SIGNATURES: Record<string, { sig: string, desc: string }> = {
    load: {
      sig: `load(reqmatch: Value, ctrl: Value) -> Result<Rc<Self>, ${errType}>`,
      desc: 'Load a single entity matching the given criteria. `Ok` is the entity, whose record `data(None)` reads, and `Err` a failure.',
    },
    list: {
      sig: `list(reqmatch: Value, ctrl: Value) -> Result<Vec<Rc<Self>>, ${errType}>`,
      desc: 'List entities matching the given criteria. The match is optional — pass `Value::Noval` to list all records. `Ok` is a `Vec` of entities, one per record.',
    },
    create: {
      sig: `create(reqdata: Value, ctrl: Value) -> Result<Rc<Self>, ${errType}>`,
      desc: 'Create a new entity with the given data. `Ok` is the created entity, and `Err` a failure.',
    },
    update: {
      sig: `update(reqdata: Value, ctrl: Value) -> Result<Rc<Self>, ${errType}>`,
      desc: 'Update an existing entity. The data must include the entity id. `Ok` is the updated entity.',
    },
    patch: {
      sig: `patch(reqdata: Value, ctrl: Value) -> Result<Rc<Self>, ${errType}>`,
      desc: 'Change part of an existing entity: only the fields given are sent. The data must include the entity id. `Ok` is the patched entity.',
    },
    remove: {
      sig: `remove(reqmatch: Value, ctrl: Value) -> Result<Rc<Self>, ${errType}>`,
      desc: 'Remove the entity matching the given criteria. `Ok` is the entity, marked as deleted, and `Err` a failure.',
    },
  }


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${model.Name}SDK

### Constructor

`)

    Content(`\`\`\`rust
use ${rustcrate}::{jo, ${model.const.Name}Entity, ${model.const.Name}SDK, Entity, Value};

let client = ${model.const.Name}SDK::new(options);
\`\`\`

Create a new SDK client instance. \`options\` is a \`Value\` map
(\`Value::Noval\` for none).

**Parameters:**

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
### Static Functions

`)

    Content(`#### \`test_sdk(testopts: Value, sdkopts: Value) -> Rc<${model.const.Name}SDK>\`

Create a test client with mock features active. Both arguments may be
\`Value::Noval\`.

\`\`\`rust
use ${rustcrate}::{test_sdk, Value};

let client = test_sdk(Value::Noval, Value::Noval);
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${rustMethodName(ent.name)}(entopts: Value) -> Rc<${ent.Name}Entity>\`

Create a new \`${ent.Name}Entity\` instance. Pass \`Value::Noval\` for no
initial options.

`)
    })


    Content(`#### \`options_map() -> Value\`

Return a deep copy of the current SDK options.

#### \`get_utility() -> Rc<Utility>\`

Return a copy of the SDK utility object.

#### \`direct(fetchargs: Value) -> Result<Value, ${errType}>\`

Make a direct HTTP request to any API endpoint. \`Ok\` is a result \`Value::Map\`
with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This
escape hatch resolves to \`Ok\` even on a non-2xx response — branch on
\`getp(&result, "ok")\`.

**Parameters (\`fetchargs\` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| \`path\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`string\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`map\` | Path parameter values. |
| \`query\` | \`map\` | Query string parameters. |
| \`headers\` | \`map\` | Request headers (merged with defaults). |
| \`body\` | \`any\` | Request body (maps are JSON-serialized). |

#### \`prepare(fetchargs: Value) -> Result<Value, ${errType}>\`

Prepare a fetch definition without sending. Returns the fetchdef on \`Ok\`.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = Object.values(ent.fields || {})
      const idF = entityIdField(ent)
      const eVar = rustVarName(ent.name)
      const method = rustMethodName(ent.name)

      Content(`
---

## ${ent.Name}Entity

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`rust
let ${eVar} = client.${method}(Value::Noval);
\`\`\`

`)


      // Field schema
      if (fields.length > 0) {
        Content(`### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
`)
        each(fields, (field: any) => {
          const req = field.r ? 'Yes' : 'No'
          const desc = field.sh || ''
          Content(`| \`${field.n}\` | \`${canonToType(field.t, target.name)}\` | ${req} | ${desc} |
`)
        })

        Content(`
`)

        // Field operations breakdown
        const hasFieldOps = fields.some((f: any) => f.op && Object.keys(f.op).length > 0)
        if (hasFieldOps) {
          const opcols = ['load', 'list', 'create', 'update', 'patch', 'remove']
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
            Content(`| \`${field.n}\` | ${cols.join(' | ')} |
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

          if (opNeedsAction(ent.op[opname])) {
            return
          }

          if ('load' === opname || 'remove' === opname) {
            const matchItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const arg = 0 < matchItems.length
              ? `jo(vec![${matchItems.map((it: any) =>
                `("${it.name}", ${rustLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)})`).join(', ')}])`
              : 'Value::Noval'
            Content(`\`\`\`rust
let result = client.${method}(Value::Noval).${opname}(${arg}, Value::Noval).unwrap();
println!("{:?}", result.data(None));
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`rust
let results = client.${method}(Value::Noval).list(${rustListMatch(ent)}, Value::Noval).unwrap();
for ${eVar} in &results {
    println!("{:?}", ${eVar}.data(None));
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`rust
let result = client.${method}(Value::Noval).create(jo(vec![
`)
            createItems.map((it: any) => {
              Content(`    ("${it.name}", ${rustLit(it.type, 'example_' + it.name)}),  // ${canonToType(it.type, target.name)}
`)
            })
            Content(`]), Value::Noval).unwrap();
\`\`\`

`)
          }
          else if ('update' === opname || 'patch' === opname) {
            const updateItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `    ("${it.name}", ${rustLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)}),\n`).join('')
            Content(`\`\`\`rust
let result = client.${method}(Value::Noval).${opname}(jo(vec![
${updateLines}    // ${'patch' === opname ? 'Only the fields to change' : 'Fields to update'}
]), Value::Noval).unwrap();
\`\`\`

`)
          }

          if ('create' === opname || 'update' === opname || 'patch' === opname) {
            const note = bodyNote(ent.op[opname], {
              values: 'a string, or bytes as `bytes_value(&[u8])`',
            })
            if ('' !== note) Content(note)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data(args: Option<&Value>) -> Value\`

Get the entity data. Pass \`Some(&map)\` to set it.

#### \`matchv(args: Option<&Value>) -> Value\`

Get the entity match criteria. Pass \`Some(&map)\` to set it.

#### \`make() -> Rc<dyn Entity>\`

Create a new \`${ent.Name}Entity\` instance with the same options.

#### \`get_name() -> String\`

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

      Content(`\`\`\`rust
let client = ${model.const.Name}SDK::new(jo(vec![
    ("feature", jo(vec![
`)
      activeFeatures.map((f: any) => {
        Content(`        ("${f.name}", jo(vec![("active", Value::Bool(true))])),
`)
      })
      Content(`    ])),
]));
\`\`\`

`)
      ReadmeRefFeatures({ target })
    }

  })
})


export {
  ReadmeRef
}
