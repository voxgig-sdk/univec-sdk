
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { swiftVarName } from './utility_swift'


// A type-correct Swift `Value` literal for a field's canonical type.
function swiftLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '.int(1)'
  if ('NUMBER' === k) return '.double(1.0)'
  if ('BOOLEAN' === k) return '.bool(true)'
  if ('ARRAY' === k) return '.list([])'
  if ('OBJECT' === k) return '.map(VMap())'
  return '.string("example")'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? exampleEntity.Name : 'Entity'
  const eVar = exampleEntity ? swiftVarName(exampleEntity.name) : 'entity'
  // Model-driven id key: null when the entity has no id-like field, so a
  // match op takes an empty match.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'nil'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `VMap([("${idF}", .string("test01"))])` : 'nil'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `VMap([${chosen.map((it: any) =>
      `("${it.name}", ${swiftLit(it.type)})`).join(', ')}])`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = primaryOp
    ? `// Entity ops return the ENTITY and throws on error;
// call data() for the record.
let ${eVar} = try client.${eName}().${primaryOp}(${testArg}, nil)
// ${eVar} holds the mock response record
print(${eVar})`
    : `let result = client.direct(VMap([
    ("path", .string("/api/resource")),
    ("method", .string("GET")),
]))
print(result)`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`swift
let result = client.direct(VMap([
    ("path", .string("/api/resource/{id}")),
    ("method", .string("GET")),
    ("params", .map([("id", .string("example"))])),
]))

if result.entries["ok"] == .bool(true) {
    print(result.entries["status"] ?? .noval)  // 200
    print(result.entries["data"] ?? .noval)     // response body
}
else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present, so
    // an absent key simply reads as .noval.
    print(result.entries["status"] ?? .noval, result.entries["err"] ?? .noval)
}
\`\`\`

### Prepare a request without sending it

\`\`\`swift
// prepare() returns the fetch definition and throws on error.
let fetchdef = try client.prepare(VMap([
    ("path", .string("/api/resource/{id}")),
    ("method", .string("DELETE")),
    ("params", .map([("id", .string("example"))])),
]))

print(fetchdef.entries["url"] ?? .noval)
print(fetchdef.entries["method"] ?? .noval)
print(fetchdef.entries["headers"] ?? .noval)
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`swift
let client = ${SDK}.testSDK(nil, nil)

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own \`SystemFetch\` closure:

\`\`\`swift
let fetch: SystemFetch = { url, _ in
    let m = VMap()
    m.entries["status"] = .int(200)
    m.entries["statusText"] = .string("OK")
    m.entries["headers"] = .map(VMap())
    m.entries["json"] = .nat({ () -> Value in .map(VMap([("id", .string("mock01"))])) } as NativeCall0)
    return .map(m)
}

let system = VMap()
system.entries["fetch"] = .nat(fetch)
let options = VMap()
options.entries["base"] = .string("http://localhost:8080")
options.entries["system"] = .map(system)
let client = ${SDK}(options)
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd swift && make test
\`\`\`

`)

})


export {
  ReadmeHowto
}
