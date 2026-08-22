
import { cmp, Content, isAuthActive, envName, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { elixirLit } from './utility_elixir'


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eVar = exampleEntity ? exampleEntity.name : 'entity'
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'H.deep(%{})'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `H.deep(%{"${idF}" => "test01"})` : 'H.deep(%{})'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `H.deep(%{${chosen.map((it: any) => `"${it.name}" => ${elixirLit(it.type)}`).join(', ')}})`
  }

  const resVar = 'list' === primaryOp ? 'records' : 'record'
  const testModeExample = primaryOp
    ? `# Entity ops return the bare record (raise on error).
${eVar} = ${Name}.${eVar}(sdk)
${resVar} = ${Name}.Entity.${eName}.${primaryOp}(${eVar}, ${testArg})
IO.inspect(${resVar})`
    : `result = ${Name}.direct(sdk, H.deep(%{"path" => "/api/resource", "method" => "GET"}))
IO.inspect(result)`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity operations. \`direct/2\` never raises —
it returns a result node you branch on with \`Voxgig.Struct.getprop/2\`:

\`\`\`elixir
alias Voxgig.Struct, as: S
alias ${Name}.Helpers, as: H

result = ${Name}.direct(sdk, H.deep(%{
  "path" => "/api/resource/{id}",
  "method" => "GET",
  "params" => %{"id" => "example"}
}))

if S.getprop(result, "ok") do
  IO.inspect(S.getprop(result, "status"))  # 200
  IO.inspect(S.getprop(result, "data"))    # response body
else
  # A non-2xx response carries status + data (the error body); a
  # transport-level failure carries err instead.
  IO.inspect(S.getprop(result, "err"))
end
\`\`\`

### Prepare a request without sending it

\`\`\`elixir
alias ${Name}.Helpers, as: H

# prepare/2 returns the fetch definition and raises on error.
fetchdef = ${Name}.prepare(sdk, H.deep(%{
  "path" => "/api/resource/{id}",
  "method" => "DELETE",
  "params" => %{"id" => "example"}
}))

IO.inspect(Voxgig.Struct.getprop(fetchdef, "url"))
IO.inspect(Voxgig.Struct.getprop(fetchdef, "method"))
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`elixir
alias ${Name}.Helpers, as: H

sdk = ${Name}.test()

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own function. It receives \`(url,
fetchdef)\` and returns a \`{response, error}\` tuple:

\`\`\`elixir
alias Voxgig.Struct, as: S
alias ${Name}.Helpers, as: H

mock_fetch = fn _url, _fetchdef ->
  response = H.deep(%{
    "status" => 200,
    "statusText" => "OK",
    "headers" => %{},
    "json" => fn -> %{"id" => "mock01"} end
  })
  {response, nil}
end

sdk = ${Name}.new(H.deep(%{
  "base" => "http://localhost:8080",
  "system" => %{"fetch" => mock_fetch}
}))
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && mix test
\`\`\`

`)

})


export {
  ReadmeHowto
}
