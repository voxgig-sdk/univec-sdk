
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as \`Value\`

The Zig SDK uses a single dynamic \`Value\` type throughout rather than a
typed struct per entity. \`Value\` is the vendored voxgig struct port's
\`JsonValue\` (a JSON-shaped tagged union: \`.string\`, \`.integer\`,
\`.float\`, \`.bool\`, \`.array\`, \`.object\`, \`.null\`). This mirrors the
dynamic nature of the API and keeps the SDK flexible — no code generation is
needed when the API schema changes.

Build request maps with the \`h.jo\` / \`h.ja\` helpers and read fields back
with \`h.getp\` (or the typed \`h.get_str\` / \`h.get_bool\` / \`h.to_int\`
accessors); use \`h.to_map\` to safely coerce a value to a map.

### Module structure

\`\`\`
${target.name}/
├── root.zig                     -- Module root (re-exports the public surface)
├── build.zig                    -- Build + test wiring
├── core/                        -- Pipeline types, config, client (sdk.zig)
├── entity/                      -- Per-entity clients (one file each)
├── feature/                     -- Built-in features (base, test, log)
├── utility/                     -- Utilities + the vendored voxgig struct port
└── test/                        -- Test suites
\`\`\`

The public API is re-exported from \`root.zig\`, so \`@import("sdk")\` reaches
the SDK client, \`Value\`, and the \`h\` (helpers) namespace directly. Import
entity or utility modules only when needed.

`)

})


export {
  ReadmeExplanation
}
