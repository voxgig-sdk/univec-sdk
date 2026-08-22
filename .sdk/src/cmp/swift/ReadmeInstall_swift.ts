
import { cmp, Content, isPublished, repoInfo, packageVersion } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`Add the package as a dependency in your \`Package.swift\`:

\`\`\`swift
dependencies: [
    .package(url: "<repo-url>", from: "${packageVersion(model, target.name)}"),
],
\`\`\`

Or build from a source checkout — the SDK is a plain SwiftPM package:

\`\`\`bash
cd swift && swift build
\`\`\`

`)
    return
  }

  // Publish pending: not yet on the SwiftPM registry (git-tag only). The
  // generated SDK is a dependency-free SwiftPM package (Foundation + the
  // vendored Voxgig Struct port), so install it from the git release tag or a
  // local source checkout and build with SwiftPM.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to a SwiftPM registry. The generated SDK
is a dependency-free SwiftPM package (Foundation only, plus the vendored
Voxgig Struct port). Depend on it from the GitHub release tag
(\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) by adding it to
your \`Package.swift\`:

\`\`\`swift
dependencies: [
    // From the git release tag:
    .package(url: "<repo-url>", exact: "${packageVersion(model, target.name)}"),
],
\`\`\`

Or build from a source checkout with SwiftPM:

\`\`\`bash
cd swift && swift build
\`\`\`

`)
})


export {
  ReadmeInstall
}
