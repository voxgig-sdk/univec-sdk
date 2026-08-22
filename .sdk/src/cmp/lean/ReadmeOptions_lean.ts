import { cmp, Content } from '@voxgig/sdkgen'

const ReadmeOptions = cmp(function ReadmeOptions(_props: any) {
  Content(`Options are a struct \`Value\` map passed to \`Sdk.newSdk\`:

| Option | Meaning |
| --- | --- |
| \`base\` | API base URL (overrides the built-in default) |
| \`prefix\` / \`suffix\` | Path fragments wrapped around every request path |
| \`headers\` | Default request headers (merged with per-request headers) |
| \`apikey\` | Bearer/api key, sent via the \`authorization\` header |
| \`entity\` | Per-entity option overrides, keyed by entity name |

\`\`\`lean
let opts ← newMap #[("base", .str "https://api.example.com"), ("apikey", .str key)]
let sdk ← Sdk.newSdk opts
\`\`\`

`)
})

export { ReadmeOptions }
