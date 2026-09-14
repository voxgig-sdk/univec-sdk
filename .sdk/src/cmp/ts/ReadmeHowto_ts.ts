
import { cmp, Content, isAuthActive, isHttpBasicAuth, envName, entityIdField, entityDataIdField, pickExampleEntity, opRequestShape, safeVarName, exampleVarName, jsKey } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { exampleValue } from './utility_ts'


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity like Cloudsmith's `Abort`. primaryOp is null
  // only when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  // Variable-safe lowercase name (a `Delete` entity must not bind `delete`).
  const eVar = exampleVarName(eName.toLowerCase(), 'ts')

  const primaryOpDef = exampleEntity && primaryOp && exampleEntity.op && exampleEntity.op[primaryOp]
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  // Model-driven id key: `idF` is the entity's id-like MATCH field name, or null
  // when it has none. `dataIdF` is the id on the RETURNED record's data type —
  // reading `.id` off a record whose data type has none is a TS2339.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const dataIdF = exampleEntity ? entityDataIdField(exampleEntity) : null

  // A type-correct, language-idiomatic argument for the primary op call.
  const primaryArg = (idPlaceholder: string): string => {
    if (!exampleEntity || !primaryOp) return ''
    if ('list' === primaryOp) return ''
    if (isMatchOp) {
      // Every REQUIRED match key (id first), not just idF — a composite-match
      // entity (e.g. Umbrella's FlatPermission, database_id + id) needs them all
      // to satisfy the typed <Name>LoadMatch. Mirrors ReadmeTopTest.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) => (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      if (0 === items.length) return ''
      const pairs = items.map((it: any) =>
        `${jsKey(it.name)}: ${exampleValue(exampleEntity, primaryOpDef, it.name,
          it.name === idF ? idPlaceholder : 'example_' + it.name)}`)
      return `{ ${pairs.join(', ')} }`
    }
    // create / update: a body of the required writable fields.
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    const pairs = chosen.map((it: any) =>
      `${jsKey(it.name)}: ${exampleValue(exampleEntity, primaryOpDef, it.name, 'example_' + it.name)}`)
    return `{ ${pairs.join(', ')} }`
  }
  const testCallArg = primaryArg('test01')
  const stateCallArg = primaryArg('example')
  // Only read `.id` off the returned record when its data type carries one.
  const stateDataLine = dataIdF
    ? `console.log(data.${dataIdF})`
    : `console.log(data)`

  // The op-driven example lines, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() test call instead.
  const testModeExample = primaryOp
    ? `const ${eVar} = await client.${eName}().${primaryOp}(${testCallArg})
// ${eVar} is the entity, populated with mock response data
// — call ${eVar}.data() for the record itself
console.log(${eVar})`
    : `const result = await client.direct({ path: '/api/resource', method: 'GET' })
console.log(result)`
  const stateSection = primaryOp
    ? `### Retain entity state across calls

Entity instances remember their last match and data:

\`\`\`ts
const entity = client.${eName}()

// First call runs the operation and stores its result
await entity.${primaryOp}(${stateCallArg})

// Subsequent calls reuse the stored state
const data = entity.data()
${stateDataLine}
\`\`\`

`
    : ''

  const authActive = isAuthActive(model)
  const authBasic = authActive && isHttpBasicAuth(model)
  const apikeyTesterCtor = authActive
    ? `new ${model.const.Name}SDK({ apikey: '...'${authBasic ? `, secret: '...'` : ''} })`
    : `new ${model.const.Name}SDK()`
  const apikeyExtendField = authActive
    ? `\n  apikey: '...',${authBasic ? `\n  secret: '...',` : ''}`
    : ''
  const apikeyEnvLine = authActive
    ? `\n${envName(model)}_APIKEY=<your-key>${authBasic ? `\n${envName(model)}_SECRET=<your-secret>` : ''}`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`ts
const result = await client.direct({
  path: '/api/resource/{id}',
  method: 'GET',
  params: { id: 'example' },
})

if (result instanceof Error) {
  throw result
}
if (result.ok) {
  console.log(result.status)  // 200
  console.log(result.data)    // response body
}
\`\`\`

### Prepare a request without sending it

\`\`\`ts
const fetchdef = await client.prepare({
  path: '/api/resource/{id}',
  method: 'DELETE',
  params: { id: 'example' },
})

// Inspect before sending
console.log(fetchdef.url)
console.log(fetchdef.method)
console.log(fetchdef.headers)
\`\`\`

### Use test mode

Create a mock client for unit testing \u2014 no server required:

\`\`\`ts
const client = ${model.const.Name}SDK.test()

${testModeExample}
\`\`\`

You can also use the instance method:

\`\`\`ts
const client = ${apikeyTesterCtor}
const testClient = client.tester()
\`\`\`

${stateSection}### Add custom middleware

Pass features via the \`extend\` option:

\`\`\`ts
const logger = {
  hooks: {
    PreRequest: (ctx: any) => {
      console.log('Requesting:', ctx.spec.method, ctx.spec.path)
    },
    PreResponse: (ctx: any) => {
      console.log('Status:', ctx.out.request?.status)
    },
  },
}

const client = new ${model.const.Name}SDK({${apikeyExtendField}
  extend: [logger],
})
\`\`\`

### Run live tests

Supply your API key through the environment or a configured secrets provider,
then enable live execution for the generated suite:

\`\`\`bash
cd ts && ${envName(model)}_TEST_LIVE=TRUE npm test
\`\`\`

Live entity flows record each operation's outcome and continue independent
work after errors. Cleanup runs after ordinary steps. Missing prerequisites
are reported as blocked; failures and blocked required steps produce a nonzero
exit status after the remaining work completes. Offline feature and utility
tests still run in the same suite.

To supply the key from Boru without writing it to a file, configure the vault
folder/suffix and run:

\`\`\`bash
${envName(model)}_TEST_LIVE=TRUE boru vault exec sdk:${model.name}=${envName(model)}_APIKEY -- npm test
\`\`\`

The \`npm run test:live\` command runs the same eight-route scenario suite
without the offline tests. It covers public model discovery and key issuance,
account embedding/conversion/bridge calls, and the three ephemeral routes.
Conversion uses actual source embeddings and catalogue dimensions. Failed
prerequisites block their dependants; independent calls continue.

Use the existing vault explicitly:

\`\`\`bash
${envName(model)}_TEST_LIVE=TRUE boru vault --folder="$HOME/.vxgboru01" --suffix=sdk01 exec sdk:${model.name}=${envName(model)}_APIKEY -- npm test
\`\`\`

The final LIVE SUMMARY records eight planned routes. A complete run has eight
passed routes and zero failed or blocked routes. Key issuance has no deletion
endpoint; the suite reuses that key for the three ephemeral calls and never
prints it.

`)

})


export {
  ReadmeHowto
}
