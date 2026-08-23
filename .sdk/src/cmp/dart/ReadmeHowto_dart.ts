
import { cmp, Content, isAuthActive, envName, canonKey, canonScalarKey, entityIdField, pickExampleEntity, opRequestShape, safeVarName, exampleVarName } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'


// A type-correct Dart literal for a field's canonical type.
function dartLit(type: any): string {
  const k = canonScalarKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '<dynamic>[]'
  if ('OBJECT' === k) return '<String, dynamic>{}'
  return "'example'"
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity. primaryOp is null only when NO entity
  // exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eVar = exampleVarName(eName.toLowerCase(), 'dart')
  // Model-driven id key: null when the entity has no id-like field.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = ''
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `{'${idF}': 'test01'}` : ''
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `{${chosen.map((it: any) => `'${it.name}': ${dartLit(it.type)}`).join(', ')}}`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = primaryOp
    ? `// Entity ops return the ENTITY and throws on error;
// call data() for the record.
final ${eVar} = await client.${eName}().${primaryOp}(${testArg});
// ${eVar} contains the mock response record
print(${eVar});`
    : `final result = await client.direct({'path': '/api/resource', 'method': 'GET'});
print(result);`

  const apikeyEnvLine = isAuthActive(model)
    ? `\nexport ${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`dart
final result = await client.direct({
  'path': '/api/resource/{id}',
  'method': 'GET',
  'params': {'id': 'example'},
});

if (true == result['ok']) {
  print(result['status']);  // 200
  print(result['data']);    // response body
} else {
  // A non-2xx response carries status + data (the error body); a
  // transport-level failure carries err instead. direct() never throws —
  // branch on result['ok'].
  print(result['status']);
  print(result['err']);
}
\`\`\`

### Prepare a request without sending it

\`\`\`dart
// prepare() returns the fetch definition (or an error value on failure).
final fetchdef = await client.prepare({
  'path': '/api/resource/{id}',
  'method': 'DELETE',
  'params': {'id': 'example'},
});

print(fetchdef['url']);
print(fetchdef['method']);
print(fetchdef['headers']);
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`dart
final client = ${model.const.Name}SDK.test();

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own function:

\`\`\`dart
Future<dynamic> mockFetch(dynamic url, dynamic init) async {
  return {
    'status': 200,
    'statusText': 'OK',
    'headers': <String, dynamic>{},
    'json': () => {'id': 'mock01'},
  };
}

final client = ${model.const.Name}SDK({
  'base': 'http://localhost:8080',
  'system': {
    'fetch': mockFetch,
  },
});
\`\`\`

### Run live tests

Set the live-mode environment variables:

\`\`\`bash
export ${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && dart run test/main.dart
\`\`\`

`)

})


export {
  ReadmeHowto
}
