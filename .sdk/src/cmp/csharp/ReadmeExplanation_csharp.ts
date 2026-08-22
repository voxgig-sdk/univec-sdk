
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as dictionaries

The C# SDK uses a loose object model — \`Dictionary<string, object?>\`
throughout — rather than a bespoke typed class per endpoint. This mirrors
the dynamic nature of the API and keeps the SDK flexible: no regeneration is
needed when the API schema changes.

Use \`Helpers.ToMapAny(value)\` to safely coerce a value to a
\`Dictionary<string, object?>\`. A \`${model.const.Name}Types.cs\` module of
reference \`record\` types is also generated for editor documentation.

### Project structure

\`\`\`
csharp/
├── ${model.const.Name}SDK.csproj    -- Library project (compiles everything except test/)
├── core/                       -- Main SDK client, config, entity base, error type
├── entity/                     -- Entity implementations
├── feature/                    -- Built-in features (Base, Test, Log, ...)
├── utility/                    -- Utility functions and the vendored struct library
└── test/                       -- xUnit test suites
\`\`\`

The main client class (\`${model.const.Name}SDK\`, namespace
\`${model.const.Name}Sdk\`) exposes the entity accessors. Reference entity or
utility types directly only when needed.

`)

})


export {
  ReadmeExplanation
}
