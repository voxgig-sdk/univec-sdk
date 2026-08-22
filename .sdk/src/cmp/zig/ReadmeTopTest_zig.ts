
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { zigVarName } from './utility_zig'


// A type-correct zig expression constructing a voxgig struct Value.
function zigLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'h.vnum(1)'
  if ('BOOLEAN' === k) return 'h.vbool(true)'
  if ('ARRAY' === k) return 'h.olist()'
  if ('OBJECT' === k) return 'h.omap()'
  return 'h.vstr("example")'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`zig
const std = @import("std");
const sdk = @import("sdk");
const h = sdk.h;

const client = sdk.test_sdk(h.vnull(), h.vnull());
`)

  if (exampleEntity && primaryOp) {
    const method = zigVarName(exampleEntity.name)
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'h.vnull()'
    if (isMatchOp) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request match.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `h.jo(&.{${items.map((it: any) =>
          `.{ "${it.name}", ${it.name === idF ? 'h.vstr("test01")' : zigLit(it.type)} }`).join(', ')}})`
        : 'h.vnull()'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = 0 < chosen.length
        ? `h.jo(&.{${chosen.map((it: any) => `.{ "${it.name}", ${zigLit(it.type)} }`).join(', ')}})`
        : 'h.omap()'
    }
    const eVar = zigVarName(exampleEntity.name) + ('list' === primaryOp ? 's' : '')
    Content(`switch (client.${method}(h.vnull()).${primaryOp}(${arg}, h.vnull())) {
    .ok => |${eVar}| std.debug.print("{s}\\n", .{h.stringify(${eVar})}),
    .err => |e| std.debug.print("${primaryOp} failed: {s}\\n", .{e.msg}),
}
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
