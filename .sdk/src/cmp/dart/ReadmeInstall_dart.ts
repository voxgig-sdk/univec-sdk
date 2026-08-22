
import { cmp, Content, isPublished, repoInfo, packageVersion } from '@voxgig/sdkgen'

import { dartPackageName } from './Package_dart'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  const pkg = dartPackageName(model)

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
dart pub add ${pkg}
\`\`\`

Or add it to your \`pubspec.yaml\`:

\`\`\`yaml
dependencies:
  ${pkg}: ^${packageVersion(model, target.name)}
\`\`\`

`)
    return
  }

  // Publish pending: not yet on pub.dev. Depend on it via the git release
  // tag, or from a local path checkout.
  const { repoUrl, releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to pub.dev. Add it as a git
dependency (pinned to a release tag \`${target.name}/vX.Y.Z\`, see
[Releases](${releasesUrl})) in your \`pubspec.yaml\`:

\`\`\`yaml
dependencies:
  ${pkg}:
    git:
      url: ${repoUrl}
      path: ${target.name}
      ref: ${target.name}/v${packageVersion(model, target.name)}
\`\`\`

Or depend on a local source checkout:

\`\`\`yaml
dependencies:
  ${pkg}:
    path: ../${target.name}
\`\`\`

`)
})


export {
  ReadmeInstall
}
