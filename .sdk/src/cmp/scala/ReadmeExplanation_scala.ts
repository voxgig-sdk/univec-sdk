
import { cmp, Content } from '@voxgig/sdkgen'

import { scalaPackage } from './utility_scala'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  const pkg = scalaPackage(model)

  Content(`### Data as maps

The Scala SDK uses a loose object model — \`java.util.Map[String, Object]\`
throughout — rather than a bespoke typed class per endpoint. This mirrors the
dynamic nature of the API and keeps the SDK flexible: no regeneration is
needed when the API schema changes.

Use \`Helpers.toMapAny(value)\` to safely coerce a value to a
\`java.util.Map[String, Object]\`. A \`${model.const.Name}Types.scala\` module of
reference \`case class\` types is also generated for editor documentation.

### Project structure

\`\`\`
scala/
├── project.scala               -- scala-cli project config (Scala 3, no deps)
├── core/                        -- Main SDK client, config, entity base, error type
├── entity/                      -- Entity implementations
├── feature/                     -- Built-in features (Base, Test, Log, ...)
├── utility/                     -- Utility functions and the vendored struct library
└── sdktest/                     -- Generated per-entity tests (scala-cli mains)
\`\`\`

The main client class (\`${model.const.Name}SDK\`, package \`${pkg}.core\`)
exposes the entity accessors. Reference entity or utility types directly only
when needed. The SDK is a dependency-free scala-cli project: JSON parsing is
the vendored \`utility/Json.java\`, HTTP transport is the JDK
\`java.net.http.HttpClient\`, and the struct library is inlined under
\`utility/struct\`.

`)

})


export {
  ReadmeExplanation
}
