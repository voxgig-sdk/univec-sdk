
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { javaVarName } from './utility_java'


// A type-correct Java literal for a field's canonical type.
function javaLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'List.of()'
  if ('OBJECT' === k) return 'Map.of()'
  return '"example"'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eVar = exampleEntity ? javaVarName(exampleEntity.name) : 'entity'
  const accessor = exampleEntity ? javaVarName(exampleEntity.name) : 'entity'
  // Model-driven id key: null when the entity has no id-like field, so a
  // match op takes an empty match.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'null'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `Map.of("${idF}", "test01")` : 'null'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `Map.of(${chosen.map((it: any) =>
      `"${it.name}", ${javaLit(it.type)}`).join(', ')})`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = primaryOp
    ? `// Entity ops return the ENTITY and raises on error;
// call data() for the record.
Object ${eVar} = client.${accessor}(null).${primaryOp}(${testArg}, null);
// ${eVar} holds the mock response record
System.out.println(${eVar});`
    : `Map<String, Object> result = client.direct(Map.of(
    "path", "/api/resource",
    "method", "GET"));
System.out.println(result);`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`java
Map<String, Object> result = client.direct(Map.of(
    "path", "/api/resource/{id}",
    "method", "GET",
    "params", Map.of("id", "example")));

if (Boolean.TRUE.equals(result.get("ok"))) {
    System.out.println(result.get("status"));  // 200
    System.out.println(result.get("data"));    // response body
}
else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present, so
    // read both — an absent key simply reads as null.
    System.out.println(result.get("status") + " " + result.get("err"));
}
\`\`\`

### Prepare a request without sending it

\`\`\`java
// prepare() returns the fetch definition and raises on error.
Map<String, Object> fetchdef = client.prepare(Map.of(
    "path", "/api/resource/{id}",
    "method", "DELETE",
    "params", Map.of("id", "example")));

System.out.println(fetchdef.get("url"));
System.out.println(fetchdef.get("method"));
System.out.println(fetchdef.get("headers"));
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`java
${SDK} client = ${SDK}.testSDK(null, null);

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own \`BiFunction\`:

\`\`\`java
java.util.function.BiFunction<String, Map<String, Object>, Object> mockFetch =
    (url, init) -> {
        Map<String, Object> res = new java.util.LinkedHashMap<>();
        res.put("status", 200);
        res.put("statusText", "OK");
        res.put("headers", new java.util.LinkedHashMap<String, Object>());
        res.put("json", (java.util.function.Supplier<Object>) () ->
            Map.of("id", "mock01"));
        return res;
    };

Map<String, Object> options = new java.util.LinkedHashMap<>();
options.put("base", "http://localhost:8080");
options.put("system", Map.of("fetch", mockFetch));
${SDK} client = new ${SDK}(options);
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd java && mvn test
\`\`\`

`)

})


export {
  ReadmeHowto
}
