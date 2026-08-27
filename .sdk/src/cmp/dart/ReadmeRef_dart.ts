
import { cmp, each, Content, canonToType, canonKey, canonScalarKey, File, isAuthActive, entityIdField, opRequestShape, safeVarName, exampleVarName, matchArg, idLiteral } from '@voxgig/sdkgen'
import { ReadmeRefFeatures } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { dartPackageName } from './Package_dart'


// Type names come from the shared canonToType 'dart' column (single source of truth).

// A type-correct Dart literal for a field's canonical type. Strings render
// the quoted placeholder (single-quoted, matching the generated Dart style).
function dartLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '<dynamic>[]'
  if ('OBJECT' === k) return '<String, dynamic>{}'
  return `'${placeholder}'`
}


// A `list()` on a NESTED entity needs its parent path params. The
// quickstart used to emit `client.Moon().list()` for an entity at
// `/planet/{planet_id}/moon`, which 404s against a live server from a
// half-built URL — indistinguishable from "no such record". The model
// already marks those params `reqd: true`; matchArg renders exactly them.
function listMatchArg(ent: any): string {
  const idF = entityIdField(ent)
  return matchArg('ts', ent, 'list', idF, idLiteral(ent, 'list', idF))
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'load(reqmatch, [ctrl]) -> Future<dynamic>',
    returns: 'the entity data',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and throws on error.',
  },
  list: {
    sig: 'list([reqmatch, ctrl]) -> Future<List>',
    returns: 'a list of entities',
    desc: 'List entities matching the given criteria. The match is optional — call `list()` with no argument to list all records. Returns a list of entity instances and throws on error.',
  },
  create: {
    sig: 'create(reqdata, [ctrl]) -> Future<dynamic>',
    returns: 'the created entity data',
    desc: 'Create a new entity with the given data. Returns the created entity data and throws on error.',
  },
  update: {
    sig: 'update(reqdata, [ctrl]) -> Future<dynamic>',
    returns: 'the updated entity data',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and throws on error.',
  },
  remove: {
    sig: 'remove(reqmatch, [ctrl]) -> Future<dynamic>',
    returns: 'the removed entity data',
    desc: 'Remove the entity matching the given criteria. Throws on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)
  const pkg = dartPackageName(model)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.

## ${model.const.Name}SDK

### Constructor

`)

    Content(`\`\`\`dart
import 'package:${pkg}/${model.const.Name}SDK.dart';

final client = ${model.const.Name}SDK(options);
\`\`\`

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`options\` | \`Map\` | SDK configuration options. |
${isAuthActive(model) ? '| `options[\'apikey\']` | `String` | API key for authentication. |\n' : ''}| \`options['base']\` | \`String\` | Base URL for API requests. |
| \`options['prefix']\` | \`String\` | URL prefix appended after base. |
| \`options['suffix']\` | \`String\` | URL suffix appended after path. |
| \`options['headers']\` | \`Map\` | Custom headers for all requests. |
| \`options['feature']\` | \`Map\` | Feature configuration. |
| \`options['system']\` | \`Map\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Static Methods

`)

    Content(`#### \`${model.const.Name}SDK.test([testopts, sdkopts])\`

Create a test client with mock features active. Both arguments may be \`null\`.

\`\`\`dart
final client = ${model.const.Name}SDK.test();
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${ent.Name}([entopts])\`

Create a new \`${ent.Name}Entity\` instance. Pass no argument for no initial data.

`)
    })


    Content(`#### \`options() -> Map\`

Return a deep copy of the current SDK options.

#### \`utility() -> Utility\`

Return the SDK utility object.

#### \`direct([fetchargs]) -> Future<Map>\`

Make a direct HTTP request to any API endpoint. Returns a result \`Map\` with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape hatch never throws — branch on \`result['ok']\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`fetchargs['path']\` | \`String\` | URL path with optional \`{param}\` placeholders. |
| \`fetchargs['method']\` | \`String\` | HTTP method (default: \`'GET'\`). |
| \`fetchargs['params']\` | \`Map\` | Path parameter values. |
| \`fetchargs['query']\` | \`Map\` | Query string parameters. |
| \`fetchargs['headers']\` | \`Map\` | Request headers (merged with defaults). |
| \`fetchargs['body']\` | \`dynamic\` | Request body (maps are JSON-serialized). |

**Returns:** \`Future<Map>\`

#### \`prepare([fetchargs]) -> Future\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` (or an error value on failure).

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      const idF = entityIdField(ent)
      const eVar = exampleVarName(ent.name, 'dart')

      Content(`
---

## ${ent.Name}Entity

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`dart
final ${eVar} = client.${ent.Name}();
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
              ? `{${matchItems.map((it: any) =>
                `'${it.name}': ${dartLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}`).join(', ')}}`
              : ''
            Content(`\`\`\`dart
final result = await client.${ent.Name}().${opname}(${arg});
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`dart
final results = await client.${ent.Name}().list(${listMatchArg(ent)});
for (final ${eVar} in results) {
  print(${eVar}.data());
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`dart
final result = await client.${ent.Name}().create({
`)
            createItems.map((it: any) => {
              Content(`  '${it.name}': ${dartLit(it.type, 'example_' + it.name)},  // ${canonToType(it.type, target.name)}
`)
            })
            Content(`});
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `  '${it.name}': ${dartLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)},\n`).join('')
            Content(`\`\`\`dart
final result = await client.${ent.Name}().update({
${updateLines}  // Fields to update
});
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data([d]) -> Map\`

Get the entity data, or set it when passed an argument.

#### \`match([m]) -> Map\`

Get the entity match criteria, or set it when passed an argument.

#### \`make() -> Entity\`

Create a new \`${ent.Name}Entity\` instance with the same options.

#### \`entopts() -> Map\`

Return the entity options.

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

      Content(`\`\`\`dart
final client = ${model.const.Name}SDK({
  'feature': {
`)
      activeFeatures.map((f: any) => {
        Content(`    '${f.name}': {'active': true},
`)
      })
      Content(`  },
});
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
