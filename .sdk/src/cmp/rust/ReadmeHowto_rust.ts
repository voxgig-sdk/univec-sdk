
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { crateIdent, rustVarName } from './utility_rust'


// A type-correct rust expression constructing a voxgig struct Value.
function rustLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value::Num(1.0)'
  if ('BOOLEAN' === k) return 'Value::Bool(true)'
  if ('ARRAY' === k) return 'Value::empty_list()'
  if ('OBJECT' === k) return 'Value::empty_map()'
  return 'Value::str("example")'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const rustcrate = crateIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eVar = exampleEntity ? rustVarName(exampleEntity.name) : 'entity'
  const method = exampleEntity ? rustVarName(exampleEntity.name) : 'entity'
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'Value::Noval'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `jo(vec![("${idF}", Value::str("test01"))])` : 'Value::Noval'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = 0 < chosen.length
      ? `jo(vec![${chosen.map((it: any) => `("${it.name}", ${rustLit(it.type)})`).join(', ')}])`
      : 'Value::empty_map()'
  }

  // The op-driven test-mode line. A direct()-only SDK shows a direct() call.
  const testModeExample = primaryOp
    ? `// Entity ops return the bare record on Ok and Err on failure.
let ${eVar} = client.${method}(Value::Noval).${primaryOp}(${testArg}, Value::Noval).unwrap();
// ${eVar} contains the mock response record`
    : `let result = client.direct(jo(vec![
    ("path", Value::str("/api/resource")),
    ("method", Value::str("GET")),
])).unwrap();
println!("{:?}", result);`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`rust
let result = client.direct(jo(vec![
    ("path", Value::str("/api/resource/{id}")),
    ("method", Value::str("GET")),
    ("params", jo(vec![("id", Value::str("example"))])),
])).unwrap();

if getp(&result, "ok") == Value::Bool(true) {
    println!("{:?}", getp(&result, "status"));  // 200
    println!("{:?}", getp(&result, "data"));    // response body
} else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present.
    println!("{:?} {:?}", getp(&result, "status"), getp(&result, "err"));
}
\`\`\`

### Prepare a request without sending it

\`\`\`rust
// prepare() returns the fetch definition on Ok and Err on failure.
let fetchdef = client.prepare(jo(vec![
    ("path", Value::str("/api/resource/{id}")),
    ("method", Value::str("DELETE")),
    ("params", jo(vec![("id", Value::str("example"))])),
])).unwrap();

println!("{:?}", getp(&fetchdef, "url"));
println!("{:?}", getp(&fetchdef, "method"));
println!("{:?}", getp(&fetchdef, "headers"));
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`rust
let client = test_sdk(Value::Noval, Value::Noval);

${testModeExample}
\`\`\`

### Point at a different server

Override the base URL to reach a local or staging server:

\`\`\`rust
let client = ${model.const.Name}SDK::new(jo(vec![
    ("base", Value::str("http://localhost:8080")),
]));
\`\`\`

### Run live tests

Create a \`.env.local\` file at the crate root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && cargo test
\`\`\`

`)

})


export {
  ReadmeHowto
}
