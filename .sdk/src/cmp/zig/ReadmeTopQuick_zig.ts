
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { zigVarName } from './utility_zig'


// A type-correct zig expression constructing a voxgig struct Value for a
// param. Strings render the quoted placeholder; numeric/boolean/array/object
// render a typed literal.
function zigLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'h.vnum(1)'
  if ('BOOLEAN' === k) return 'h.vbool(true)'
  if ('ARRAY' === k) return 'h.olist()'
  if ('OBJECT' === k) return 'h.omap()'
  return `h.vstr("${placeholder}")`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `sdk.${model.const.Name}SDK.new(h.jo(&.{\n    .{ "apikey", h.vstr(std.posix.getenv("${envName(model)}_APIKEY") orelse "") },\n}))`
    : `sdk.${model.const.Name}SDK.new(h.vnull())`

  Content(`\`\`\`zig
const std = @import("std");
const sdk = @import("sdk");
const h = sdk.h;

const client = ${ctor};

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = zigVarName(exampleEntity.name)
    const method = zigVarName(exampleEntity.name)
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes no match argument.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${eName.toLowerCase()}s (Ok is a Value array, .err on failure)
switch (client.${method}(h.vnull()).list(h.vnull(), h.vnull())) {
    .ok => |${eVar}s| std.debug.print("{s}\\n", .{h.stringify(${eVar}s)}),
    .err => |e| std.debug.print("list failed: {s}\\n", .{e.msg}),
}
`)
    }

    if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `h.jo(&.{${loadItems.map((it: any) =>
          `.{ "${it.name}", ${zigLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)} }`).join(', ')}})`
        : 'h.vnull()'
      Content(`
// Load a specific ${eName.toLowerCase()} (Ok is the record, .err on failure)
switch (client.${method}(h.vnull()).load(${loadArg}, h.vnull())) {
    .ok => |${eVar}| std.debug.print("{s}\\n", .{h.stringify(${eVar})}),
    .err => |e| std.debug.print("load failed: {s}\\n", .{e.msg}),
}
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
