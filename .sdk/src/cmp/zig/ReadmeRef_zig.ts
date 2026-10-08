
import { cmp, each, Content, canonKey, canonScalarKey, File, isAuthActive, entityIdField, opRequestShape , targetFeatures, opNeedsAction, bodyNote } from '@voxgig/sdkgen'
import { ReadmeRefFeatures } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { zigVarName, zigListMatch } from './utility_zig'


// Canonical type sentinel -> a zig type name for the field/param tables.
function zigType(type: any): string {
  const k = canonKey(type)
  if ('STRING' === k) return '[]const u8'
  if ('INTEGER' === k) return 'i64'
  if ('NUMBER' === k) return 'f64'
  if ('BOOLEAN' === k) return 'bool'
  if ('ARRAY' === k) return 'Value (array)'
  if ('OBJECT' === k) return 'Value (object)'
  return 'Value'
}


// A type-correct zig expression constructing a voxgig struct Value.
function zigLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'h.vnull()'
  if ('INTEGER' === k || 'NUMBER' === k) return 'h.vnum(1)'
  if ('BOOLEAN' === k) return 'h.vbool(true)'
  if ('ARRAY' === k) return 'h.olist()'
  if ('OBJECT' === k) return 'h.omap()'
  return `h.vstr("${placeholder}")`
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = targetFeatures(model, target)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)

  const OP_SIGNATURES: Record<string, { sig: string, desc: string }> = {
    load: {
      sig: 'load(reqmatch: Value, ctrl: Value) EntResult',
      desc: 'Load a single entity matching the given criteria. `.ok` carries the entity, whose record `asEntity().data(null)` reads, and `.err` the branded error.',
    },
    list: {
      sig: 'list(reqmatch: Value, ctrl: Value) EntListResult',
      desc: 'List entities matching the given criteria. The match is optional — pass `h.vnull()` to list all records. `.ok` is a slice of entities, one per record.',
    },
    create: {
      sig: 'create(reqdata: Value, ctrl: Value) EntResult',
      desc: 'Create a new entity with the given data. `.ok` carries the created entity.',
    },
    update: {
      sig: 'update(reqdata: Value, ctrl: Value) EntResult',
      desc: 'Update an existing entity. The data must include the entity id. `.ok` carries the updated entity.',
    },
    patch: {
      sig: 'patch(reqdata: Value, ctrl: Value) EntResult',
      desc: 'Change part of an existing entity: only the fields given are sent. The data must include the entity id. `.ok` carries the patched entity.',
    },
    remove: {
      sig: 'remove(reqmatch: Value, ctrl: Value) EntResult',
      desc: 'Remove the entity matching the given criteria. `.ok` carries the entity, marked as deleted, and `.err` the branded error.',
    },
  }


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${model.Name}SDK

### Constructor

`)

    Content(`\`\`\`zig
const sdk = @import("sdk");
const h = sdk.h;

const client = sdk.${model.const.Name}SDK.new(options);
\`\`\`

Create a new SDK client instance. \`options\` is a \`Value\` map
(\`h.vnull()\` for none).

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

    Content(`#### \`test_sdk(testopts: Value, sdkopts: Value) *${model.const.Name}SDK\`

Create a test client with mock features active. Both arguments may be
\`h.vnull()\`.

\`\`\`zig
const client = sdk.test_sdk(h.vnull(), h.vnull());
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${zigVarName(ent.name)}(entopts: Value) *${ent.Name}Entity\`

Create a new \`${ent.Name}Entity\` instance. Pass \`h.vnull()\` for no
initial options.

`)
    })


    Content(`#### \`options_map() Value\`

Return a deep copy of the current SDK options.

#### \`get_utility() *Utility\`

Return a copy of the SDK utility object.

#### \`direct(fetchargs: Value) Value\`

Make a direct HTTP request to any API endpoint. Returns a result \`Value\`
map with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure).
This escape hatch returns a map even on a non-2xx response — branch on
\`h.get_bool(result, "ok")\`.

**Parameters (\`fetchargs\` map keys):**

| Key | Value type | Description |
| --- | --- | --- |
| \`path\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`method\` | \`string\` | HTTP method (default: \`"GET"\`). |
| \`params\` | \`map\` | Path parameter values. |
| \`query\` | \`map\` | Query string parameters. |
| \`headers\` | \`map\` | Request headers (merged with defaults). |
| \`body\` | \`any\` | Request body (maps are JSON-serialized). |

#### \`prepare(fetchargs: Value) E!Value\`

Prepare a fetch definition without sending. Returns the fetchdef (use
\`catch\`/\`try\` to handle the error union).

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = Object.values(ent.fields || {})
      const idF = entityIdField(ent)
      const eVar = zigVarName(ent.name)
      const method = zigVarName(ent.name)

      Content(`
---

## ${ent.Name}Entity

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`zig
const ${eVar} = client.${method}(h.vnull());
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
          Content(`| \`${field.n}\` | \`${zigType(field.t)}\` | ${req} | ${desc} |
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
              ? `h.jo(&.{${matchItems.map((it: any) =>
                `.{ "${it.name}", ${zigLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)} }`).join(', ')}})`
              : 'h.vnull()'
            Content(`\`\`\`zig
switch (client.${method}(h.vnull()).${opname}(${arg}, h.vnull())) {
    .ok => |result| std.debug.print("{s}\\n", .{h.stringify(result.asEntity().data(null))}),
    .err => |e| std.debug.print("${opname} failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`zig
switch (client.${method}(h.vnull()).list(${zigListMatch(ent)}, h.vnull())) {
    .ok => |results| {
        for (results) |result| {
            std.debug.print("{s}\\n", .{h.stringify(result.asEntity().data(null))});
        }
    },
    .err => |e| std.debug.print("list failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`zig
switch (client.${method}(h.vnull()).create(h.jo(&.{
`)
            createItems.map((it: any) => {
              Content(`    .{ "${it.name}", ${zigLit(it.type, 'example_' + it.name)} }, // ${zigType(it.type)}
`)
            })
            Content(`}), h.vnull())) {
    .ok => |result| std.debug.print("{s}\\n", .{h.stringify(result.asEntity().data(null))}),
    .err => |e| std.debug.print("create failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
          }
          else if ('update' === opname || 'patch' === opname) {
            const updateItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `    .{ "${it.name}", ${zigLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)} },\n`).join('')
            Content(`\`\`\`zig
switch (client.${method}(h.vnull()).${opname}(h.jo(&.{
${updateLines}    // ${'patch' === opname ? 'Only the fields to change' : 'Fields to update'}
}), h.vnull())) {
    .ok => |result| std.debug.print("{s}\\n", .{h.stringify(result.asEntity().data(null))}),
    .err => |e| std.debug.print("${opname} failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
          }

          if ('create' === opname || 'update' === opname || 'patch' === opname) {
            const note = bodyNote(ent.op[opname], {
              values: 'a string value holding the bytes',
            })
            if ('' !== note) Content(note)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data(args: ?Value) Value\`

Get the entity data. Pass a map to set it.

#### \`matchv(args: ?Value) Value\`

Get the entity match criteria. Pass a map to set it.

#### \`stream(action: []const u8, args: Value, callopts: Value) StreamResult\`

Run an operation through the pipeline and materialise its result items.
\`StreamResult\` is \`.ok\` with the items, or \`.err\` with the error that
failed the operation, as an operation call reports it. Under \`throw: false\`
in \`callopts.ctrl\`, a failed stream is \`.ok\` with whatever data the
failure left.

#### \`get_name() []const u8\`

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

      Content(`\`\`\`zig
const client = sdk.${model.const.Name}SDK.new(h.jo(&.{
    .{ "feature", h.jo(&.{
`)
      activeFeatures.map((f: any) => {
        Content(`        .{ "${f.name}", h.jo(&.{.{ "active", h.vbool(true) }}) },
`)
      })
      Content(`    }) },
}));
\`\`\`

`)
      ReadmeRefFeatures({ target })
    }

  })
})


export {
  ReadmeRef
}
