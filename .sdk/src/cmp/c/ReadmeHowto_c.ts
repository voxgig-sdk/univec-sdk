
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { cIdent, cVarName } from './utility_c'


// A type-correct C expression constructing a voxgig struct Value.
function cLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'v_num(1)'
  if ('BOOLEAN' === k) return 'v_bool(true)'
  if ('ARRAY' === k) return 'v_list()'
  if ('OBJECT' === k) return 'v_map()'
  return 'v_str("example")'
}


// cmap(...) for a set of pairs, or NULL when empty.
function cmapExpr(pairs: string[]): string {
  return pairs.length ? `cmap(${pairs.length}, ${pairs.join(', ')})` : 'NULL'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const ident = cIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const evar = exampleEntity ? cVarName(exampleEntity.name) : 'entity'
  const acc = `${ident}_${evar}`
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'NULL'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `cmap(1, "${idF}", v_str("test01"))` : 'NULL'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = cmapExpr(chosen.map((it: any) => `"${it.name}", ${cLit(it.type)}`))
  }

  // The op-driven test-mode line. A direct()-only SDK shows a direct() call.
  const testModeExample = primaryOp
    ? `// Entity ops return the bare record and set *err on failure.
Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* ${evar}_rec = ${evar}->vt->${primaryOp}(${evar}, ${testArg}, NULL, &err);
// ${evar}_rec contains the mock response record`
    : `voxgig_value* result = sdk_direct(client, cmap(2,
    "path", v_str("/api/resource"),
    "method", v_str("GET")), &err);
printf("%s\\n", voxgig_to_json(result));`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity operations:

\`\`\`c
PNError* err = NULL;
voxgig_value* result = sdk_direct(client, cmap(3,
    "path", v_str("/api/resource/{id}"),
    "method", v_str("GET"),
    "params", cmap(1, "id", v_str("example"))), &err);

if (voxgig_as_bool(getp(result, "ok"))) {
    printf("%lld\\n", (long long)to_int(getp(result, "status")));  // 200
    printf("%s\\n", voxgig_to_json(getp(result, "data")));         // response body
} else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present.
    printf("%s\\n", voxgig_to_json(getp(result, "err")));
}
\`\`\`

\`sdk_direct()\` never sets \`*err\` for a non-2xx response — it always returns
a result map you branch on via \`getp(result, "ok")\`.

### Prepare a request without sending it

\`\`\`c
PNError* err = NULL;
voxgig_value* fetchdef = sdk_prepare(client, cmap(3,
    "path", v_str("/api/resource/{id}"),
    "method", v_str("DELETE"),
    "params", cmap(1, "id", v_str("example"))), &err);

printf("%s\\n", get_str(fetchdef, "url"));
printf("%s\\n", get_str(fetchdef, "method"));
printf("%s\\n", voxgig_to_json(getp(fetchdef, "headers")));
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`c
${model.const.Name}SDK* client = test_sdk(NULL, NULL);
PNError* err = NULL;

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own function (the same shape the test
transport uses):

\`\`\`c
static voxgig_value* mock_fetch(void* ud, voxgig_value* args) {
    (void)ud; (void)args;
    return cmap(4,
        "status", v_num(200),
        "statusText", v_str("OK"),
        "headers", v_map(),
        "json", json_thunk(cmap(1, "id", v_str("mock01"))));
}

${model.const.Name}SDK* client = ${ident}_sdk_new(cmap(2,
    "base", v_str("http://localhost:8080"),
    "system", cmap(1, "fetch", vfn(mock_fetch, NULL))));
\`\`\`

### Point at a different server

Override the base URL to reach a local or staging server:

\`\`\`c
${model.const.Name}SDK* client = ${ident}_sdk_new(cmap(1,
    "base", v_str("http://localhost:8080")));
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && make test
\`\`\`

`)

})


export {
  ReadmeHowto
}
