
import { cmp, each, Content, canonToType, canonKey, canonScalarKey, File, isAuthActive, entityIdField, opRequestShape , targetFeatures, opNeedsAction, bodyNote } from '@voxgig/sdkgen'
import { ReadmeRefFeatures } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { csVarName, csListMatch } from './utility_csharp'


// Type names come from the shared canonToType 'csharp' column (single source of truth).

// A type-correct C# literal for a field's canonical type.
function csLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'null'
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'new List<object?>()'
  if ('OBJECT' === k) return 'new Dictionary<string, object?>()'
  return `"${placeholder}"`
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'Load(reqmatch, ctrl = null) -> object?',
    returns: 'the entity',
    desc: 'Load a single entity matching the given criteria. Returns the entity, whose record `Data()` reads, and raises on error.',
  },
  list: {
    sig: 'List(reqmatch, ctrl = null) -> object?',
    returns: 'a list of entities, one per record',
    desc: 'List entities matching the given criteria. The match is optional — call `List(null)` to list all records. Returns a list of entities, one per record, and raises on error.',
  },
  create: {
    sig: 'Create(reqdata, ctrl = null) -> object?',
    returns: 'the created entity',
    desc: 'Create a new entity with the given data. Returns the created entity and raises on error.',
  },
  update: {
    sig: 'Update(reqdata, ctrl = null) -> object?',
    returns: 'the updated entity',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity and raises on error.',
  },
  patch: {
    sig: 'Patch(reqdata, ctrl = null) -> object?',
    returns: 'the patched entity',
    desc: 'Change part of an existing entity: only the fields given are sent. The data must include the entity `id`. Returns the patched entity and raises on error.',
  },
  remove: {
    sig: 'Remove(reqmatch, ctrl = null) -> object?',
    returns: 'the removed entity',
    desc: 'Remove the entity matching the given criteria. Returns the entity, marked as deleted, and raises on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = targetFeatures(model, target)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${model.const.Name}SDK

### Constructor

`)

    Content(`\`\`\`csharp
using ${model.const.Name}Sdk;
using Voxgig.Struct;

var client = new ${model.const.Name}SDK(options);
\`\`\`

Create a new SDK client instance. \`options\` is a
\`Dictionary<string, object?>\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`options\` | \`Dictionary\` | SDK configuration options. |
${isAuthActive(model) ? '| \`options["apikey"]\` | \`string\` | API key for authentication. |\n' : ''}| \`options["base"]\` | \`string\` | Base URL for API requests. |
| \`options["prefix"]\` | \`string\` | URL prefix appended after base. |
| \`options["suffix"]\` | \`string\` | URL suffix appended after path. |
| \`options["headers"]\` | \`Dictionary\` | Custom headers for all requests. |
| \`options["feature"]\` | \`Dictionary\` | Feature configuration. |
| \`options["system"]\` | \`Dictionary\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Static Methods

`)

    Content(`#### \`${model.const.Name}SDK.TestSDK(testopts = null, sdkopts = null)\`

Create a test client with mock features active. Both arguments may be \`null\`.

\`\`\`csharp
var client = ${model.const.Name}SDK.TestSDK(null, null);
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${ent.Name}(entopts = null)\`

Create a new \`${ent.Name}\` entity instance (returns
\`${model.const.Name}EntityBase\`). Pass \`null\` for no initial options.

`)
    })


    Content(`#### \`OptionsMap() -> Dictionary\`

Return a deep copy of the current SDK options.

#### \`GetUtility() -> Utility\`

Return a copy of the SDK utility object.

#### \`Direct(fetchargs = null) -> Dictionary\`

Make a direct HTTP request to any API endpoint. Returns a result
\`Dictionary<string, object?>\` with \`ok\`, \`status\`, \`headers\`, and \`data\`
(or \`err\` on failure). This escape hatch never raises — branch on
\`result["ok"]\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`fetchargs["path"]\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`fetchargs["method"]\` | \`string\` | HTTP method (default: \`"GET"\`). |
| \`fetchargs["params"]\` | \`Dictionary\` | Path parameter values. |
| \`fetchargs["query"]\` | \`Dictionary\` | Query string parameters. |
| \`fetchargs["headers"]\` | \`Dictionary\` | Request headers (merged with defaults). |
| \`fetchargs["body"]\` | \`object?\` | Request body (dictionaries are JSON-serialized). |

**Returns:** \`Dictionary<string, object?>\`

#### \`Prepare(fetchargs = null) -> Dictionary\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and raises on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = Object.values(ent.fields || {})
      // Model-driven id key: null when this entity has no id-like field.
      const idF = entityIdField(ent)
      // Sanitise the local variable name — csVarName guards C# keywords.
      const eVar = csVarName(ent.name)

      Content(`
---

## ${ent.Name}

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`csharp
var ${eVar} = client.${ent.Name}();
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
              ? `new Dictionary<string, object?> {${matchItems.map((it: any) =>
                ` ["${it.name}"] = ${csLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}`).join(',')} }`
              : 'null'
            Content(`\`\`\`csharp
var result = client.${ent.Name}().${opname.charAt(0).toUpperCase() + opname.slice(1)}(${arg});
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`csharp
var results = (List<object?>)client.${ent.Name}().List(${csListMatch(ent)})!;
foreach (var item in results)
{
    Console.WriteLine(StructUtils.Jsonify(((IEntity)item!).Data()));
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`csharp
var result = client.${ent.Name}().Create(new Dictionary<string, object?>
{
`)
            createItems.map((it: any) => {
              Content(`    ["${it.name}"] = ${csLit(it.type, 'example_' + it.name)},  // ${canonToType(it.type, target.name)}
`)
            })
            Content(`});
\`\`\`

`)
          }
          else if ('update' === opname || 'patch' === opname) {
            const updateItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `    ["${it.name}"] = ${csLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)},\n`).join('')
            Content(`\`\`\`csharp
var result = client.${ent.Name}().${'patch' === opname ? 'Patch' : 'Update'}(new Dictionary<string, object?>
{
${updateLines}    // ${'patch' === opname ? 'Only the fields to change' : 'Fields to update'}
});
\`\`\`

`)
          }

          if ('create' === opname || 'update' === opname || 'patch' === opname) {
            const note = bodyNote(ent.op[opname], {
              values: 'a `byte[]`, a `string` or a `Stream`',
              once: 'a `Stream`',
            })
            if ('' !== note) Content(note)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`Data(newdata = null) -> object?\`

Get or set the entity data.

#### \`Match(newmatch = null) -> object?\`

Get or set the entity match criteria.

#### \`Make() -> IEntity\`

Create a new \`${ent.Name}\` entity instance with the same options.

#### \`GetName() -> string\`

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

      Content(`\`\`\`csharp
var client = new ${model.const.Name}SDK(new Dictionary<string, object?>
{
    ["feature"] = new Dictionary<string, object?>
    {
`)
      activeFeatures.map((f: any) => {
        Content(`        ["${f.name}"] = new Dictionary<string, object?> { ["active"] = true },
`)
      })
      Content(`    },
});
\`\`\`

`)
      ReadmeRefFeatures({ target })
    }

  })
})


export {
  ReadmeRef
}
