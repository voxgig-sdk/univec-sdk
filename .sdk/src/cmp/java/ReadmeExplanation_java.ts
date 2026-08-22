
import { cmp, Content } from '@voxgig/sdkgen'

import { javaPackage } from './utility_java'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  const pkg = javaPackage(model)

  Content(`### Data as maps

The Java SDK uses a loose object model — \`Map<String, Object>\` throughout —
rather than a bespoke typed class per endpoint. This mirrors the dynamic
nature of the API and keeps the SDK flexible: no regeneration is needed when
the API schema changes.

Use \`Helpers.toMapAny(value)\` to safely coerce a value to a
\`Map<String, Object>\`. A \`${model.const.Name}Types.java\` module of reference
\`record\` types is also generated for editor documentation.

### Project structure

\`\`\`
java/
├── pom.xml                     -- Maven project (compiles core/, utility/, feature/, entity/)
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
