
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { zigVarName } from './utility_zig'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain
  // (relations.ancestors), an active load op, and a required non-id load
  // param to demonstrate (the parent key, e.g. page_id).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `sdk.${model.const.Name}SDK.new(h.jo(&.{\n    .{ "apikey", h.vstr(std.posix.getenv("${envName(model)}_APIKEY") orelse "") },\n}))`
    : `sdk.${model.const.Name}SDK.new(h.vnull())`

  // A type-correct zig expression constructing a voxgig struct Value.
  const zigLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonKey(type)
    if ('INTEGER' === k || 'NUMBER' === k) return 'h.vnum(1)'
    if ('BOOLEAN' === k) return 'h.vbool(true)'
    if ('ARRAY' === k) return 'h.olist()'
    if ('OBJECT' === k) return 'h.omap()'
    return `h.vstr("${placeholder}")`
  }

  Content(`### 1. Create a client

\`\`\`zig
const std = @import("std");
const sdk = @import("sdk");
const h = sdk.h;

const client = ${ctor};
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const eVar = zigVarName(exampleEntity.name)
    const method = zigVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list()\` returns an \`OpResult\` whose \`.ok\` is a \`Value\` array —
\`switch\` on it.

\`\`\`zig
switch (client.${method}(h.vnull()).list(h.vnull(), h.vnull())) {
    .ok => |${eVar}s| std.debug.print("{s}\\n", .{h.stringify(${eVar}s)}),
    .err => |e| std.debug.print("list failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = zigVarName(nestedEntity.name)
      const neMethod = zigVarName(nestedEntity.name)

      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `.{ "${it.name}", ${zigLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)} }`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\`'s \`.ok\` carries the bare record.

\`\`\`zig
switch (client.${neMethod}(h.vnull()).load(h.jo(&.{${neMatch.join(', ')}}), h.vnull())) {
    .ok => |${neVar}| std.debug.print("{s}\\n", .{h.stringify(${neVar})}),
    .err => |e| std.debug.print("load failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `h.jo(&.{${loadRequired.map((it: any) =>
          `.{ "${it.name}", ${zigLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)} }`).join(', ')}})`
        : 'h.vnull()'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\`'s \`.ok\` carries the bare record.

\`\`\`zig
switch (client.${method}(h.vnull()).load(${loadArg}, h.vnull())) {
    .ok => |${eVar}| std.debug.print("{s}\\n", .{h.stringify(${eVar})}),
    .err => |e| std.debug.print("load failed: {s}\\n", .{e.msg}),
}
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape so the docs reference REAL writable fields.
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `.{ "${it.name}", ${zigLit(it.type, 'example_' + it.name)} }`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    // The id VALUE for an update/remove match: a type-correct literal (zig
    // ops return an OpResult, so threading the created record's id through a
    // switch scope would obscure the example).
    const idValueFor = (opname: string): string => zigLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`zig
`)
      if (opnames.includes('create')) {
        Content(`// Create — .ok carries the created record
switch (client.${method}(h.vnull()).create(h.jo(&.{${examplePairs('create').join(', ')}}), h.vnull())) {
    .ok => |created| std.debug.print("{s}\\n", .{h.stringify(created)}),
    .err => |e| std.debug.print("create failed: {s}\\n", .{e.msg}),
}

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`.{ "${idF}", ${idValueFor('update')} }`] : []).concat(examplePairs('update'))
        Content(`// Update
switch (client.${method}(h.vnull()).update(h.jo(&.{${updatePairs.join(', ')}}), h.vnull())) {
    .ok => |updated| std.debug.print("{s}\\n", .{h.stringify(updated)}),
    .err => |e| std.debug.print("update failed: {s}\\n", .{e.msg}),
}

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `.{ "${it.name}", ${idValueFor('remove')} }`
            : `.{ "${it.name}", ${zigLit(it.type, 'example_' + it.name)} }`)
        Content(`// Remove
switch (client.${method}(h.vnull()).remove(${removePairs.length ? `h.jo(&.{${removePairs.join(', ')}})` : 'h.vnull()'}, h.vnull())) {
    .ok => |_| std.debug.print("removed\\n", .{}),
    .err => |e| std.debug.print("remove failed: {s}\\n", .{e.msg}),
}
`)
      }
      Content(`\`\`\`

`)
    }
  }
})


export {
  ReadmeQuick
}
