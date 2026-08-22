
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as struct value maps

The Clojure SDK represents API data with the vendored \`voxgig.struct\`
value model (ordered, Java-backed maps and lists) rather than typed
records. This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

Build request maps with \`(vs/jm "k" v ...)\` and lists with
\`(vs/jt v ...)\`; read values with \`(vs/getprop m "k")\`. Use
\`(vs/ismap x)\` to safely check that a value is a map.

### Namespace structure

\`\`\`
${target.name}/
├── src/sdk/api.clj        -- public API namespace (entity accessors)
├── src/sdk/client.clj     -- client constructors (make-sdk, test-sdk)
├── src/sdk/config.clj     -- generated configuration
├── src/sdk/core.clj       -- core types, context and pipeline
├── src/sdk/features.clj   -- feature factory
├── src/sdk/entity/        -- entity namespaces (one per entity)
├── src/voxgig/struct.clj  -- vendored struct value library
└── test/                  -- test suites
\`\`\`

Require \`[sdk.api :as api]\` for the public surface, and an entity
namespace (e.g. \`[sdk.entity.${model.const.Name.toLowerCase()} :as e-${model.const.Name.toLowerCase()}]\`)
only when you call its operations directly.

`)

})


export {
  ReadmeExplanation
}
