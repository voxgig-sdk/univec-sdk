
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { hsVarName } from './utility_haskell'


// A type-correct Haskell `Value` literal for a field's canonical type.
function hsLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'VNum 1'
  if ('BOOLEAN' === k) return 'VBool True'
  if ('ARRAY' === k || 'OBJECT' === k) return 'VNoval'
  return 'VStr "example"'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eFn = exampleEntity ? hsVarName(exampleEntity.name) : 'entity'
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArgExpr = 'emptyMap'
  if (exampleEntity && isMatchOp) {
    testArgExpr = idF ? `jo [("${idF}", VStr "test01")]` : 'emptyMap'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArgExpr = `jo [${chosen.map((it: any) => `("${it.name}", ${hsLit(it.type)})`).join(', ')}]`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  const testModeExample = primaryOp
    ? `  ent <- Sdk.${eFn} sdk VNoval
  arg <- ${testArgExpr}
  ctrl <- emptyMap
  -- Entity ops return the bare record and raise on error.
  ${eFn} <- Sdk.e${primaryOp.charAt(0).toUpperCase() + primaryOp.slice(1)} ent arg ctrl
  print ${eFn}`
    : `  args <- jo [("path", VStr "/api/resource"), ("method", VStr "GET")]
  result <- F.direct sdk args
  print result`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity accessors, use \`direct\` — it never
raises and returns a result \`Value\` you branch on via its \`ok\` field:

\`\`\`haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..))
import SdkHelpers (jo, getp)

main :: IO ()
main = do
  sdk <- Sdk.newSdk0
  params <- jo [("id", VStr "example")]
  args <- jo [("path", VStr "/api/resource/{id}"), ("method", VStr "GET"), ("params", params)]
  result <- F.direct sdk args
  ok <- getp result "ok"
  case ok of
    VBool True -> do
      status <- getp result "status"   -- e.g. VNum 200
      body <- getp result "data"       -- the response body
      print (status, body)
    _ -> do
      -- A non-2xx response carries status + data (the error body); a
      -- transport-level failure carries err instead.
      status <- getp result "status"
      err <- getp result "err"
      print (status, err)
\`\`\`

### Prepare a request without sending it

\`\`\`haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..))
import SdkHelpers (jo, getp)

main :: IO ()
main = do
  sdk <- Sdk.newSdk0
  params <- jo [("id", VStr "example")]
  args <- jo [("path", VStr "/api/resource/{id}"), ("method", VStr "DELETE"), ("params", params)]
  -- prepare returns the fetch definition and raises on error.
  fetchdef <- F.prepare sdk args
  url <- getp fetchdef "url"
  method <- getp fetchdef "method"
  print (url, method)
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..), emptyMap)
import SdkHelpers (jo)

main :: IO ()
main = do
  sdk <- Sdk.testSdk0
${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own \`VFunc\` under \`system.fetch\`:

\`\`\`haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo, jsonThunk)

customClient :: IO Sdk.Client
customClient = do
  let mockFetch = VFunc (\\_ _ _ _ -> do
        body <- jo [("id", VStr "mock01")]
        jo [("status", VNum 200), ("statusText", VStr "OK"), ("json", jsonThunk body)])
  sys <- jo [("fetch", mockFetch)]
  opts <- jo [("base", VStr "http://localhost:8080"), ("system", sys)]
  Sdk.newSdk opts
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run the suite (stock GHC, no third-party dependencies):

\`\`\`bash
cd ${target.name} && make test
\`\`\`

`)

})


export {
  ReadmeHowto
}
