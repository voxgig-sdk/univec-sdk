import { cmp, Content } from '@voxgig/sdkgen'

const ReadmeExplanation = cmp(function ReadmeExplanation(_props: any) {
  Content(`The SDK is **config-driven**: the API model is embedded as JSON in
\`SdkConfig.lean\` and parsed into a \`Value\` when a client is constructed. An
operation looks up its entity and op in that model, selects the matching
endpoint (a point whose \`select.exist\` keys are satisfied), builds the URL from
the point's path parts, applies the request transform, performs the call, then
applies the response transform. Because the pipeline is data-driven rather than
generated per entity, every entity and every API follow exactly the same path.

The HTTP transport shells out to \`curl\` via \`IO.Process\` — Lean 4 has no HTTP
library in its standard distribution, and this keeps the package free of Lake
dependencies.

`)
})

export { ReadmeExplanation }
