import { cmp, Content } from '@voxgig/sdkgen'

// The Lean stanza of the top-level (multi-language) README quick start.
const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target } = props
  Content(`\`\`\`lean
import SdkClient
open VoxgigStruct

def main : IO Unit := do
  let ctx ← mkCtx
  (do
    let sdk ← Sdk.newSdk (← emptyMap)
    IO.println s!"client ready"
  ).run ctx
\`\`\`

Build it with \`cd ${target.name} && lake build\`.

`)
})

export { ReadmeTopQuick }
