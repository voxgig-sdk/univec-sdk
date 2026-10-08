
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape, requiredItems, javaMapOf } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { scalaVarName, scalaLit } from './utility_scala'


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eVar = exampleEntity ? scalaVarName(exampleEntity.name) : 'entity'
  const accessor = exampleEntity ? scalaVarName(exampleEntity.name) : 'entity'
  // Model-driven id key: null when the entity has no id-like field, so a
  // match op takes an empty match.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'null'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `java.util.Map.of("${idF}", "test01")` : 'null'
  } else if (exampleEntity && 'list' === primaryOp && 0 < requiredItems(exampleEntity, 'list').length) {
    const chosen = requiredItems(exampleEntity, 'list')
    testArg = javaMapOf(chosen.map((it: any) =>
      `${JSON.stringify(it.name)}, ${scalaLit(it.type)}`), 'java.util.')
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp || 'patch' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = javaMapOf(chosen.map((it: any) =>
      `${JSON.stringify(it.name)}, ${scalaLit(it.type)}`), 'java.util.')
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = 'list' === primaryOp
    ? `// list returns a list of entities, one per mock record; it raises on error.
val ${eVar}List = client.${accessor}(null).list(${testArg}, null).asInstanceOf[java.util.List[SdkEntity]]
${eVar}List.forEach(${eVar}Item => println(${eVar}Item.data()))`
    : primaryOp
    ? `// Entity ops return the entity; they raise on error.
val ${eVar} = client.${accessor}(null).${primaryOp}(${testArg}, null).asInstanceOf[SdkEntity]
// data() reads the entity's mock record
println(${eVar}.data())`
    : `val result = client.direct(java.util.Map.of(
    "path", "/api/resource",
    "method", "GET"))
println(result)`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`scala
val result = client.direct(java.util.Map.of(
    "path", "/api/resource/{id}",
    "method", "GET",
    "params", java.util.Map.of("id", "example")))

if (java.lang.Boolean.TRUE == result.get("ok")) {
    println(result.get("status"))  // 200
    println(result.get("data"))    // response body
}
else {
    // A non-2xx response carries status + data (the error body); a
    // transport-level failure carries err instead. Only one is present, so
    // read both — an absent key simply reads as null.
    println("status=" + result.get("status") + " err=" + result.get("err"))
}
\`\`\`

### Prepare a request without sending it

\`\`\`scala
// prepare() returns the fetch definition and raises on error.
val fetchdef = client.prepare(java.util.Map.of(
    "path", "/api/resource/{id}",
    "method", "DELETE",
    "params", java.util.Map.of("id", "example")))

println(fetchdef.get("url"))
println(fetchdef.get("method"))
println(fetchdef.get("headers"))
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`scala
val client = ${SDK}.testSDK(null, null)

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own \`BiFunction\`:

\`\`\`scala
val mockFetch: java.util.function.BiFunction[String, java.util.Map[String, Object], Object] =
    (url, init) => {
        val res = new java.util.LinkedHashMap[String, Object]()
        res.put("status", java.lang.Integer.valueOf(200))
        res.put("statusText", "OK")
        res.put("headers", new java.util.LinkedHashMap[String, Object]())
        res.put("json", (() => java.util.Map.of("id", "mock01")): java.util.function.Supplier[Object])
        res
    }

val options = new java.util.LinkedHashMap[String, Object]()
options.put("base", "http://localhost:8080")
options.put("system", java.util.Map.of("fetch", mockFetch))
val client = new ${SDK}(options)
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd scala && make test
\`\`\`

`)

})


export {
  ReadmeHowto
}
