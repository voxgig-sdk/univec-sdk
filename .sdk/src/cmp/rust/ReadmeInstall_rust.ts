
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'

import { crateName } from './utility_rust'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or add it as a path dependency in your \`Cargo.toml\`:

\`\`\`toml
[dependencies]
${crateName(model)} = { path = "../${target.name}" }
\`\`\`

`)
    return
  }

  // Publish pending: not yet on crates.io. Depend on the git release tag or
  // on a local source checkout via a path dependency.
  const { releasesUrl } = repoInfo(model)
  Content(`This crate is not yet published to crates.io. Depend on it from the GitHub
release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) or
from a source checkout by adding it to your \`Cargo.toml\`:

\`\`\`toml
[dependencies]
# From a source checkout:
${crateName(model)} = { path = "../${target.name}" }

# Or from the git release tag:
# ${crateName(model)} = { git = "<repo-url>", tag = "${target.name}/vX.Y.Z" }
\`\`\`

`)
})


export {
  ReadmeInstall
}
