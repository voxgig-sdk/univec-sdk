
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as struct Values

The Haskell SDK models every API record as the dynamic \`Value\` type (from
the vendored \`VoxgigStruct\` module) rather than bespoke Haskell records.
This mirrors the dynamic nature of the API and keeps the SDK flexible — no
new datatypes or code generation are needed when the API schema changes.

Build request maps with \`jo [(key, value)]\` and read fields back with
\`getp value "field"\`; scalars are the \`VStr\` / \`VNum\` / \`VBool\`
constructors, and \`VNoval\` stands for an absent property.

### Module structure

\`\`\`
${target.name}/
├── src/
│   ├── VoxgigStruct.hs   -- vendored dependency-free struct library (Value)
│   ├── Vregex.hs         -- vendored regex support
│   ├── SdkTypes.hs       -- core types (Client, Entity, Feature)
│   ├── SdkHelpers.hs     -- helper functions (jo, getp, ...)
│   ├── SdkRuntime.hs     -- the generic operation pipeline
│   ├── SdkFeatures.hs    -- built-in features + makeEntity
│   ├── SdkConfig.hs      -- generated API configuration + feature factory
│   └── SdkClient.hs      -- generated public client (newSdk, entity accessors)
├── test/                 -- test suites
├── Makefile              -- stock-GHC build/test (no third-party deps)
└── ${model.const.Name.toLowerCase()}-sdk.cabal      -- package manifest (for Hackage)
\`\`\`

The public module (\`SdkClient\`) exports the SDK constructors (\`newSdk\`,
\`testSdk\`) and one accessor per entity. Import \`VoxgigStruct\` for the
\`Value\` constructors and \`SdkHelpers\` for \`jo\` / \`getp\`.

`)

})


export {
  ReadmeExplanation
}
