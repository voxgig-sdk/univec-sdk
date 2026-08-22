
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as \`Value\`

The C++ SDK uses a single dynamic \`sdk::Value\` type (a JSON-like variant
over string / number / bool / list / map) throughout rather than generated
typed structs. This mirrors the dynamic nature of the API and keeps the
SDK flexible — no code generation is needed when the API schema changes.

Build maps with \`sdk::vmap({{"key", sdk::Value("v")}})\` and lists with
\`sdk::vlist({...})\`; read fields back with \`sdk::getp(value, "key")\`. Use
\`sdk::to_map()\` to safely coerce a value that should be a map, and
\`sdk::Struct::jsonify(value)\` to render it as JSON.

### Directory structure

\`\`\`
${target.name}/
├── core/                        -- Runtime type graph, config, generated client
├── entity/                      -- Per-entity client headers
├── feature/                     -- Built-in features (Base, Test, Log, ...)
├── utility/                     -- Operation pipeline + vendored struct library
├── test/                        -- Test suites
├── Makefile                     -- Build & run the tests (C++17)
└── VERSION                      -- SDK version
\`\`\`

Include the umbrella header \`core/sdk.hpp\` to pull in the whole SDK: the
runtime types, the pipeline utilities, the vendored struct, the generated
config, the per-entity clients and the generated \`${model.const.Name}SDK\`
client class. Everything lives in the \`sdk\` namespace.

`)

})


export {
  ReadmeExplanation
}
