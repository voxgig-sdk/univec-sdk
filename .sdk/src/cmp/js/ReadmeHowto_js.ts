
import { cmp, Content, isAuthActive, envName, entityIdField, entityDataIdField, pickExampleEntity, opRequestShape, safeVarName, exampleVarName, jsKey } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { exampleValue } from './utility_js'


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity like Cloudsmith's `Abort`. primaryOp is null
  // only when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eVar = exampleVarName(eName.toLowerCase(), 'js')

  const primaryOpDef = exampleEntity && primaryOp && exampleEntity.op && exampleEntity.op[primaryOp]
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  // idF is the MATCH key; dataIdF is the id on the RETURNED record's data type
  // (guard `.id` reads off a returned record on this, not the match key).
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const dataIdF = exampleEntity ? entityDataIdField(exampleEntity) : null

  const primaryArg = (idPlaceholder: string): string => {
    if (!exampleEntity || !primaryOp) return ''
    if ('list' === primaryOp) return ''
    if (isMatchOp) {
      // Every REQUIRED match key (id first), not just idF — a composite-match
      // entity (database_id + id) needs them all. Mirrors ReadmeTopTest.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) => (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      if (0 === items.length) return ''
      const pairs = items.map((it: any) =>
        `${jsKey(it.name)}: ${exampleValue(exampleEntity, primaryOpDef, it.name,
          it.name === idF ? idPlaceholder : 'example_' + it.name)}`)
      return `{ ${pairs.join(', ')} }`
    }
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
  const stateDataLine = dataIdF
    ? `console.log(data.${dataIdF})`
    : `console.log(data)`

  // The op-driven example lines, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() test call instead
  // and omits the stateful section (there is no op to retain state across).
  const testModeExample = primaryOp
    ? `const ${eVar} = await client.${eName}().${primaryOp}(${testCallArg})
// ${eVar} is a bare entity populated with mock response data
console.log(${eVar})`
    : `const result = await client.direct({ path: '/api/resource', method: 'GET' })
console.log(result)`
  const stateSection = primaryOp
    ? `### Retain entity state across calls

Entity instances remember their last match and data:

\`\`\`js
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
  const apikeyTesterCtor = authActive
    ? `new ${model.const.Name}SDK({ apikey: '...' })`
    : `new ${model.const.Name}SDK()`
  const apikeyExtendField = authActive ? `\n  apikey: '...',` : ''
  const apikeyEnvLine = authActive ? `\n${envName(model)}_APIKEY=<your-key>` : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`js
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

\`\`\`js
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

Create a mock client for unit testing — no server required:

\`\`\`js
const client = ${model.const.Name}SDK.test()

${testModeExample}
\`\`\`

You can also use the instance method:

\`\`\`js
const client = ${apikeyTesterCtor}
const testClient = client.tester()
\`\`\`

${stateSection}### Add custom middleware

Pass features via the \`extend\` option:

\`\`\`js
const logger = {
  hooks: {
    PreRequest: (ctx) => {
      console.log('Requesting:', ctx.spec.method, ctx.spec.path)
    },
    PreResponse: (ctx) => {
      console.log('Status:', ctx.out.request?.status)
    },
  },
}

const client = new ${model.const.Name}SDK({${apikeyExtendField}
  extend: [logger],
})
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd js && npm test
\`\`\`

`)

})


export {
  ReadmeHowto
}
