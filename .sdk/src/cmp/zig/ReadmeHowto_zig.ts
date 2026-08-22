
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

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


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eVar = exampleEntity ? zigVarName(exampleEntity.name) : 'entity'
  const method = exampleEntity ? zigVarName(exampleEntity.name) : 'entity'
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'h.vnull()'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `h.jo(&.{.{ "${idF}", h.vstr("test01") }})` : 'h.vnull()'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = 0 < chosen.length
      ? `h.jo(&.{${chosen.map((it: any) => `.{ "${it.name}", ${zigLit(it.type)} }`).join(', ')}})`
      : 'h.omap()'
  }

  // The op-driven test-mode line. A direct()-only SDK shows a direct() call.
  const testModeExample = primaryOp
    ? `// Entity ops return an OpResult — .ok carries the record, .err the error.
switch (client.${method}(h.vnull()).${primaryOp}(${testArg}, h.vnull())) {
    .ok => |${eVar}| std.debug.print("{s}\\n", .{h.stringify(${eVar})}), // the mock record
    .err => |e| std.debug.print("${primaryOp} failed: {s}\\n", .{e.msg}),
}`
    : `const result = client.direct(h.jo(&.{
    .{ "path", h.vstr("/api/resource") },
    .{ "method", h.vstr("GET") },
}));
std.debug.print("{s}\\n", .{h.stringify(result)});`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`zig
const result = client.direct(h.jo(&.{
    .{ "path", h.vstr("/api/resource/{id}") },
    .{ "method", h.vstr("GET") },
    .{ "params", h.jo(&.{.{ "id", h.vstr("example") }}) },
}));

if (h.get_bool(result, "ok") orelse false) {
    std.debug.print("{d}\\n", .{h.to_int(h.getp(result, "status"))}); // 200
    std.debug.print("{s}\\n", .{h.stringify(h.getp(result, "data"))}); // response body
} else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present.
    std.debug.print("{s}\\n", .{h.get_str(result, "err") orelse ""});
}
\`\`\`

### Prepare a request without sending it

\`\`\`zig
// prepare() returns the fetch definition (an error union — use \`catch\`/\`try\`).
const fetchdef = client.prepare(h.jo(&.{
    .{ "path", h.vstr("/api/resource/{id}") },
    .{ "method", h.vstr("DELETE") },
    .{ "params", h.jo(&.{.{ "id", h.vstr("example") }}) },
})) catch unreachable;

std.debug.print("{s}\\n", .{h.get_str(fetchdef, "url") orelse ""});
std.debug.print("{s}\\n", .{h.get_str(fetchdef, "method") orelse ""});
std.debug.print("{s}\\n", .{h.stringify(h.getp(fetchdef, "headers"))});
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`zig
const client = sdk.test_sdk(h.vnull(), h.vnull());

${testModeExample}
\`\`\`

### Point at a different server

Override the base URL to reach a local or staging server:

\`\`\`zig
const client = sdk.${model.const.Name}SDK.new(h.jo(&.{
    .{ "base", h.vstr("http://localhost:8080") },
}));
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && zig build test
\`\`\`

`)

})


export {
  ReadmeHowto
}
