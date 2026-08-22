
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  const SDK = model.const.Name + 'SDK'

  Content(`### Data as loose values

The Swift SDK uses a loose object model — the vendored \`Value\` enum
(with \`VMap\` / \`VList\` wrappers) throughout — rather than a bespoke typed
struct per endpoint. This mirrors the dynamic nature of the API and keeps the
SDK flexible: no regeneration is needed when the API schema changes.

Use the \`.asMap\` / \`.asList\` / \`.asString\` accessors to safely coerce a
\`Value\` to a concrete Swift type (each returns \`nil\` on a type mismatch).
A \`${model.const.Name}Types.swift\` file of reference \`struct\` types is also
generated for editor documentation.

### Project structure

\`\`\`
swift/
├── Package.swift                     -- SwiftPM manifest (zero runtime deps)
├── Sources/ProjectNameSDK/
│   ├── core/                         -- Main client, config, entity base, error type
│   ├── entity/                       -- Generated entity clients
│   ├── feature/                      -- Built-in features (Base, Test, Log, ...)
│   ├── utility/                      -- Utility functions
│   └── Struct/                       -- Vendored Voxgig Struct port
└── Tests/ProjectNameSDKTests/        -- Test suites (XCTest)
\`\`\`

The main client class (\`${SDK}\`, under \`Sources/ProjectNameSDK/core\`)
exposes the entity accessors. Reference entity or utility types directly only
when needed. The SDK is dependency-free: JSON parsing is the vendored
\`Struct/JSON.swift\`, HTTP transport is Foundation's \`URLSession\`, and the
struct library is inlined under \`Struct/\`.

`)

})


export {
  ReadmeExplanation
}
