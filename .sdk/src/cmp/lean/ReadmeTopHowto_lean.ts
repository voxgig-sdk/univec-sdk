import { cmp, Content } from '@voxgig/sdkgen'

// The Lean stanza of the top-level README how-to section.
const ReadmeTopHowto = cmp(function ReadmeTopHowto(props: any) {
  const { target } = props
  Content(`For Lean, point the client at another server with the \`base\` option,
and run the entity suite against it with \`SDK_TEST_BASE\`:

\`\`\`bash
cd ${target.name} && SDK_TEST_BASE=http://localhost:8901 lake exe runner
\`\`\`

`)
})

export { ReadmeTopHowto }
