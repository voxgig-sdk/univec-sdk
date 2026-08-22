import { cmp, Content } from '@voxgig/sdkgen'

const ReadmeHowto = cmp(function ReadmeHowto(_props: any) {
  Content(`**Handle a missing record.** A \`load\` that finds nothing yields a
non-map value, so match on it:

\`\`\`lean
match (← Entity.load sdk m (← emptyMap)) with
| .map _ => IO.println "found"
| _ => IO.println "not found"
\`\`\`

**Test without a server.** \`Sdk.testSdk0\` takes seed data (the shape of the
generated \`<Entity>TestData.json\`) and answers operations from an in-memory
store, so entity behaviour can be exercised offline:

\`\`\`lean
let seed ← SdkJson.jsonRead (← IO.FS.readFile "../.sdk/test/entity/<e>/<E>TestData.json")
let sdk ← Sdk.testSdk0 seed
\`\`\`

`)
})

export { ReadmeHowto }
