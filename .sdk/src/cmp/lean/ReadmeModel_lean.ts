import { cmp, Content } from '@voxgig/sdkgen'

const ReadmeModel = cmp(function ReadmeModel(_props: any) {
  Content(`Every value crossing the SDK boundary — options, request payloads,
responses and results — is a vendored voxgig \`Value\` (see \`VoxgigStruct.lean\`):
a JSON-shaped, heap-backed node, the Lean equivalent of the \`map[string]any\`
the Go and Python SDKs pass around. Operations run in struct's \`SIO\` monad
(\`ReaderT Ctx IO\`), so a single \`mkCtx\` is threaded through a run:

\`\`\`lean
let ctx ← mkCtx
(do
  let sdk ← Sdk.newSdk (← emptyMap)
  ...
).run ctx
\`\`\`

Build values with \`newMap\` / \`newList\`, read them with \`getprop\` / \`getpath\`,
and render them with \`stringify\` (debug) or \`jsonify\` (strict JSON).

`)
})

export { ReadmeModel }
