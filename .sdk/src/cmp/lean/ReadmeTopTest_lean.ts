import { cmp, Content } from '@voxgig/sdkgen'

// The Lean stanza of the top-level README test section.
const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target } = props
  Content(`\`\`\`bash
cd ${target.name}
lake build
lake exe primary        # shared corpus: request-shaping utilities
lake exe feature        # the feature catalog (retry, cache, rbac, netsim, …)
lake exe structcorpus   # shared corpus: the vendored struct model
lake exe runner         # entity behaviour (offline; add SDK_TEST_BASE for live)
\`\`\`

`)
})

export { ReadmeTopTest }
