
import { cmp, each, Content, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { zigVarName } from './utility_zig'


// Canonical type sentinel -> a zig type name for the field/param tables.
// (The shared canonToType helper has no zig column, so map locally.) Every
// value is dynamically a `Value`, so the type column is documentary.
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
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'h.vnum(1)'
  if ('BOOLEAN' === k) return 'h.vbool(true)'
  if ('ARRAY' === k) return 'h.olist()'
  if ('OBJECT' === k) return 'h.omap()'
  return `h.vstr("${placeholder}")`
}


// Operation method descriptions (language-agnostic wording, zig signatures).
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load(reqmatch, ctrl)',   desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list(reqmatch, ctrl)',   desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create(reqdata, ctrl)',  desc: 'Create a new entity with the given data.' },
  update: { method: 'update(reqdata, ctrl)',  desc: 'Update an existing entity.' },
  remove: { method: 'remove(reqmatch, ctrl)', desc: 'Remove the matching entity.' },
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
    const idF = entityIdField(entity)
    const eVar = zigVarName(entity.name)
    const method = zigVarName(entity.name)

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`const ${eVar} = client.${method}(h.vnull());\`

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
Each operation returns an \`OpResult\` — \`switch\` on it: \`.ok => |data|\`
carries the result \`Value\`, \`.err => |e|\` carries the branded error.

`)
    }

    if (fields.length > 0) {
      Content(`#### Fields

| Field | Type | Description |
| --- | --- | --- |
`)

      each(fields, (field: any) => {
        const desc = field.short || ''
        Content(`| \`${field.name}\` | \`${zigType(field.type)}\` | ${desc} |
`)
      })

      Content(`
`)
    }

    if (opnames.includes('load')) {
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `h.jo(&.{${loadItems.map((it: any) =>
          `.{ "${it.name}", ${zigLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)} }`).join(', ')}})`
        : 'h.vnull()'
      Content(`#### Example: Load

\`\`\`zig
switch (client.${method}(h.vnull()).load(${loadArg}, h.vnull())) {
    .ok => |${eVar}| std.debug.print("{s}\\n", .{h.stringify(${eVar})}),
    .err => |e| std.debug.print("load failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`zig
switch (client.${method}(h.vnull()).list(h.vnull(), h.vnull())) {
    .ok => |${eVar}s| std.debug.print("{s}\\n", .{h.stringify(${eVar}s)}),
    .err => |e| std.debug.print("list failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`zig
switch (client.${method}(h.vnull()).create(h.jo(&.{
`)
      createItems.map((it: any) => {
        Content(`    .{ "${it.name}", ${zigLit(it.type, 'example_' + it.name)} }, // ${zigType(it.type)}
`)
      })
      Content(`}), h.vnull())) {
    .ok => |${eVar}| std.debug.print("{s}\\n", .{h.stringify(${eVar})}),
    .err => |e| std.debug.print("create failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
