
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


// A type-correct C++ literal for a field's canonical type.
function cppLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value(1)'
  if ('BOOLEAN' === k) return 'Value(true)'
  if ('ARRAY' === k) return 'vlist()'
  if ('OBJECT' === k) return 'vmap()'
  return 'Value("example")'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity. primaryOp is null only when NO entity
  // exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const acc = exampleEntity ? cppVarName(exampleEntity.name) : 'entity'
  const eVar = acc
  // Model-driven id key: null when the entity has no id-like field.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'Value::undef()'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `vmap({{"${idF}", Value("test01")}})` : 'Value::undef()'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `vmap({${chosen.map((it: any) => `{"${it.name}", ${cppLit(it.type)}}`).join(', ')}})`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = primaryOp
    ? `// Entity ops return the bare record and throw on error.
Value ${eVar} = client->${acc}()->${primaryOp}(${testArg}, Value::undef());
// ${eVar} contains the mock response record
std::cout << Struct::jsonify(${eVar}) << std::endl;`
    : `Value result = client->direct(vmap({
    {"path", Value("/api/resource")},
    {"method", Value("GET")},
}));
std::cout << Struct::jsonify(result) << std::endl;`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`cpp
Value result = client->direct(vmap({
    {"path", Value("/api/resource/{id}")},
    {"method", Value("GET")},
    {"params", vmap({{"id", Value("example")}})},
}));

if (getp(result, "ok") == Value(true)) {
  std::cout << Helpers::toInt(getp(result, "status")) << std::endl;  // 200
  std::cout << Struct::jsonify(getp(result, "data")) << std::endl;   // response body
} else {
  // A non-2xx response carries status + data (the error body); a
  // transport-level failure carries err instead. Only one is present.
  std::cerr << Helpers::toInt(getp(result, "status")) << " "
            << Struct::jsonify(getp(result, "err")) << std::endl;
}
\`\`\`

\`direct()\` is the escape hatch: it never throws — branch on
\`getp(result, "ok")\`.

### Prepare a request without sending it

\`\`\`cpp
// prepare() returns the fetch definition and throws on error.
Value fetchdef = client->prepare(vmap({
    {"path", Value("/api/resource/{id}")},
    {"method", Value("DELETE")},
    {"params", vmap({{"id", Value("example")}})},
}));

std::cout << Struct::stringify(getp(fetchdef, "url")) << std::endl;
std::cout << Struct::stringify(getp(fetchdef, "method")) << std::endl;
std::cout << Struct::jsonify(getp(fetchdef, "headers")) << std::endl;
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required. The test
feature installs an in-memory mock transport:

\`\`\`cpp
auto client = ${model.const.Name}SDK::testSDK();

${testModeExample}
\`\`\`

You can seed the mock store by passing test options — see the generated
\`test/\` suite for worked examples.

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then build and run the test suite:

\`\`\`bash
cd ${target.name} && make test
\`\`\`

`)

})


export {
  ReadmeHowto
}
