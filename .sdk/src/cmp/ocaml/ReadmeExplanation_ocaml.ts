
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as \`value\`

The OCaml SDK uses a single dynamic \`value\` type throughout rather than a
typed record per entity. \`value\` is the vendored voxgig struct port (a
JSON-shaped variant: \`Str\`, \`Num\`, \`Bool\`, \`List\`, \`Map\`, \`Null\`,
\`Noval\`). This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

Build request maps with the \`jo\` / \`ja\` helpers and read fields back with
\`getp\`; use \`to_map\` to safely coerce a value to a map.

### Module structure

\`\`\`
${target.name}/
├── sdk_client.ml               -- Main SDK client (constructors + accessors)
├── sdk_config.ml               -- Embedded API config + feature factory
├── sdk_error.ml                -- Branded error re-exports
├── sdk_entity_*.ml             -- Per-entity implementations (one each)
├── sdk_types.ml                -- Core pipeline types
├── sdk_helpers.ml              -- jo / ja / getp and friends
├── sdk_runtime.ml              -- Operation pipeline runner
├── sdk_features.ml             -- Built-in features (base, test, log)
├── utility/                    -- Vendored voxgig struct port
└── test/                       -- Test suites
\`\`\`

The public surface lives in \`Sdk_client\` (the constructors and per-entity
accessors); \`Sdk_helpers\` carries the \`jo\` / \`ja\` / \`getp\` value
helpers. Open the runtime modules directly only when needed.

`)

})


export {
  ReadmeExplanation
}
