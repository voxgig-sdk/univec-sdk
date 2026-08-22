import { cmp, Content, isAuthActive, envName } from '@voxgig/sdkgen'
import { KIT, getModelPath } from '@voxgig/apidef'

// A capitalised entity op namespace + a representative read op for the example.
function pickEntity(model: any): { ns: string, op: string } | null {
  const entity = getModelPath(model, `main.${KIT}.entity`)
  const ents = Object.values(entity || {}).filter((e: any) => e.active !== false)
  for (const e of ents as any[]) {
    const ops = Object.keys(e.op || {})
    const op = ops.includes('list') ? 'list' : ops[0]
    if (op) {
      return { ns: e.name.charAt(0).toUpperCase() + e.name.slice(1), op }
    }
  }
  return null
}

const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { ctx$: { model } } = props
  const pick = pickEntity(model)
  const ns = pick ? pick.ns : 'Entity'
  const op = pick ? pick.op : 'list'
  const auth = isAuthActive(model)
  const optLines = [`("base", .str "https://api.example.com")`]
  if (auth) {
    optLines.push(`("apikey", .str (← IO.getEnv "${envName(model)}").getD "")`)
  }

  Content(`Construct a client with \`Sdk.newSdk\` and call an entity op. Everything runs
in struct's \`SIO\` monad, so wrap your calls and \`.run\` them on a fresh \`mkCtx\`:

\`\`\`lean
import SdkClient

open VoxgigStruct

def main : IO Unit := do
  let ctx ← mkCtx
  (do
    let opts ← newMap #[${optLines.join(', ')}]
    let sdk ← Sdk.newSdk opts
    let result ← ${ns}.${op} sdk (← emptyMap) (← emptyMap)
    IO.println s!"result: {← stringify result}"
  ).run ctx
\`\`\`

`)
})

export { ReadmeQuick }
