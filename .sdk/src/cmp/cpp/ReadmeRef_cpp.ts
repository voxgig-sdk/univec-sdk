
import { cmp, each, Content, canonToType, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


// Type names come from the shared canonToType 'cpp' column (single source of truth).

// A type-correct C++ literal for a field's canonical type.
function cppLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value(1)'
  if ('BOOLEAN' === k) return 'Value(true)'
  if ('ARRAY' === k) return 'vlist()'
  if ('OBJECT' === k) return 'vmap()'
  return `Value("${placeholder}")`
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'load(reqmatch, ctrl) -> Value',
    returns: 'the entity data',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and throws on error.',
  },
  list: {
    sig: 'list(reqmatch, ctrl) -> Value',
    returns: 'a list of entities',
    desc: 'List entities matching the given criteria. The match is optional — pass `Value::undef()` to list all records. Returns a Value list and throws on error.',
  },
  create: {
    sig: 'create(reqdata, ctrl) -> Value',
    returns: 'the created entity data',
    desc: 'Create a new entity with the given data. Returns the created entity data and throws on error.',
  },
  update: {
    sig: 'update(reqdata, ctrl) -> Value',
    returns: 'the updated entity data',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and throws on error.',
  },
  remove: {
    sig: 'remove(reqmatch, ctrl) -> Value',
    returns: 'the removed entity data',
    desc: 'Remove the entity matching the given criteria. Throws on error.',
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


## ${model.Name}SDK

### Constructor

`)

    Content(`\`\`\`cpp
#include "core/sdk.hpp"

using namespace sdk;

auto client = std::make_shared<${model.const.Name}SDK>(options);
\`\`\`

Create a new SDK client instance. \`options\` is an \`sdk::Value\` map.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`options\` | \`Value\` | SDK configuration options (a map). |
${isAuthActive(model) ? '| `options["apikey"]` | `std::string` | API key for authentication. |\n' : ''}| \`options["base"]\` | \`std::string\` | Base URL for API requests. |
| \`options["prefix"]\` | \`std::string\` | URL prefix appended after base. |
| \`options["suffix"]\` | \`std::string\` | URL suffix appended after path. |
| \`options["headers"]\` | \`Value\` | Custom headers for all requests. |
| \`options["feature"]\` | \`Value\` | Feature configuration. |
| \`options["system"]\` | \`Value\` | System overrides. |

`)


    Content(`
### Static Methods

`)

    Content(`#### \`${model.const.Name}SDK::testSDK(testopts, sdkopts)\`

Create a test client with mock features active. Both arguments may be
\`Value::undef()\`; a no-arg overload is also provided.

\`\`\`cpp
auto client = ${model.const.Name}SDK::testSDK();
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      const acc = cppVarName(ent.name)
      Content(`#### \`${acc}(entopts = Value::undef()) -> std::shared_ptr<${ent.Name}Entity>\`

Create a new \`${ent.Name}Entity\` instance bound to this client.

`)
    })


    Content(`#### \`optionsMap() -> Value\`

Return a deep copy of the current SDK options.

#### \`getUtility() -> UtilityPtr\`

Return a copy of the SDK utility object.

#### \`direct(fetchargs) -> Value\`

Make a direct HTTP request to any API endpoint. Returns a result \`Value\` with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape hatch never throws — branch on \`getp(result, "ok")\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`fetchargs["path"]\` | \`std::string\` | URL path with optional \`{param}\` placeholders. |
| \`fetchargs["method"]\` | \`std::string\` | HTTP method (default: \`"GET"\`). |
| \`fetchargs["params"]\` | \`Value\` | Path parameter values. |
| \`fetchargs["query"]\` | \`Value\` | Query string parameters. |
| \`fetchargs["headers"]\` | \`Value\` | Request headers (merged with defaults). |
| \`fetchargs["body"]\` | \`Value\` | Request body (maps are JSON-serialized). |

**Returns:** \`Value\` (result map)

#### \`prepare(fetchargs) -> Value\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and throws on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      // Model-driven id key: null when this entity has no id-like field.
      const idF = entityIdField(ent)
      const acc = cppVarName(ent.name)

      Content(`
---

## ${ent.Name}Entity

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`cpp
auto ${acc} = client->${acc}();
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
          Content(`| \`${field.name}\` | \`${canonToType(field.type, target.name)}\` | ${req} | ${desc} |
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
              ? `vmap({${matchItems.map((it: any) =>
                `{"${it.name}", ${cppLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}}`).join(', ')}})`
              : 'Value::undef()'
            Content(`\`\`\`cpp
Value result = client->${acc}()->${opname}(${arg}, Value::undef());
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`cpp
Value results = client->${acc}()->list(Value::undef(), Value::undef());
for (const auto& ${acc} : *results.as_list()) {
  std::cout << Struct::jsonify(${acc}) << std::endl;
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`cpp
Value result = client->${acc}()->create(vmap({
`)
            createItems.map((it: any) => {
              Content(`    {"${it.name}", ${cppLit(it.type, 'example_' + it.name)}},  // ${canonToType(it.type, target.name)}
`)
            })
            Content(`}), Value::undef());
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `    {"${it.name}", ${cppLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)}},\n`).join('')
            Content(`\`\`\`cpp
Value result = client->${acc}()->update(vmap({
${updateLines}    // Fields to update
}), Value::undef());
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data(arg = Value::undef()) -> Value\`

Get the entity data (no argument) or set it (with a map argument).

#### \`match(arg = Value::undef()) -> Value\`

Get the entity match criteria (no argument) or set it (with a map argument).

#### \`make() -> EntityPtr\`

Create a new \`${ent.Name}Entity\` instance with the same options.

#### \`getName() -> std::string\`

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

      Content(`\`\`\`cpp
auto client = std::make_shared<${model.const.Name}SDK>(vmap({
    {"feature", vmap({
`)
      activeFeatures.map((f: any) => {
        Content(`        {"${f.name}", vmap({{"active", Value(true)}})},
`)
      })
      Content(`    })},
}));
\`\`\`

`)
    }

  })
})




export {
  ReadmeRef
}
