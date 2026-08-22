import { cmp, Content, isPublished, repoInfo } from '@voxgig/sdkgen'

const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
cd ${target.name} && lake build
\`\`\`

`)
    return
  }

  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to [Reservoir](https://reservoir.lean-lang.org).
Install it from the GitHub release tag (\`${target.name}/vX.Y.Z\`, see
[Releases](${releasesUrl})) or from a source checkout. The runtime is
dependency-free (only the Lean 4 prelude + Std; the HTTP transport shells out
to \`curl\`), so a plain Lake build is all that is needed:

\`\`\`bash
cd ${target.name} && lake build
\`\`\`

Run the offline struct-corpus test (no server needed) and the live entity
tests (point them at a server with \`SDK_TEST_BASE\`):

\`\`\`bash
lake exe structcorpus
SDK_TEST_BASE=http://localhost:8901 lake exe runner
\`\`\`

`)
})

export { ReadmeInstall }
