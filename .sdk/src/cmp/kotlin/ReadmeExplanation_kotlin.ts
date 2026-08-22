
import { cmp, Content } from '@voxgig/sdkgen'

import { kotlinPackage } from './utility_kotlin'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  const pkg = kotlinPackage(model)

  Content(`### Data as maps

The Kotlin SDK uses a loose object model — \`MutableMap<String, Any?>\`
throughout — rather than a bespoke typed class per endpoint. This mirrors the
dynamic nature of the API and keeps the SDK flexible: no regeneration is
needed when the API schema changes.

Use \`Helpers.toMapAny(value)\` to safely coerce a value to a
\`MutableMap<String, Any?>\`. A \`${model.const.Name}Types.kt\` module of
reference \`data class\` types is also generated for editor documentation.

### Project structure

\`\`\`
kotlin/
├── build.gradle.kts            -- Gradle build (compiles core/, utility/, feature/, entity/)
├── settings.gradle.kts         -- Gradle project settings
├── core/                       -- Main SDK client, config, entity base, error type
├── entity/                     -- Entity implementations
├── feature/                    -- Built-in features (Base, Test, Log, ...)
├── utility/                    -- Utility functions and the vendored struct library
└── test/                       -- JUnit test suites
\`\`\`

The main client class (\`${model.const.Name}SDK\`, package \`${pkg}.core\`)
exposes the entity accessors. Reference entity or utility types directly only
when needed.

`)

})


export {
  ReadmeExplanation
}
