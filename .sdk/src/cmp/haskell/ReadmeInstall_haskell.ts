
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or build from a source checkout with the bundled Makefile (stock GHC, no
third-party dependencies — only the GHC boot libraries):

\`\`\`bash
cd ${target.name} && make test
\`\`\`

`)
    return
  }

  // Publish pending: not yet on Hackage. Build from the git release tag or
  // from a local source checkout. The runtime is dependency-free, so no cabal
  // solve is needed — the Makefile drives stock GHC directly.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to Hackage. Install it from the GitHub
release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) or
from a source checkout. The runtime has no third-party dependencies (only the
GHC boot libraries: \`base\`, \`containers\`, \`array\`, \`time\`), so the
bundled Makefile drives stock GHC with no cabal solve:

\`\`\`bash
cd ${target.name} && make test
\`\`\`

A \`.cabal\` file is also generated for use with \`cabal\`/\`stack\`:

\`\`\`bash
cd ${target.name} && cabal build
\`\`\`

`)
})


export {
  ReadmeInstall
}
