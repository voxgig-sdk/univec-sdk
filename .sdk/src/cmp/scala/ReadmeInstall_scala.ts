
import { cmp, Content, isPublished, repoInfo, packageVersion } from '@voxgig/sdkgen'

import { mavenGroupId } from './utility_scala'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  const groupId = mavenGroupId(model)
  const artifactId = `${model.name}-sdk`

  if (isPublished(model, target.name)) {
    Content(`Add the dependency with scala-cli:

\`\`\`scala
//> using dep "${groupId}:${artifactId}_3:${packageVersion(model, target.name)}"
\`\`\`

Or, with sbt:

\`\`\`scala
libraryDependencies += "${groupId}" %% "${artifactId}" % "${packageVersion(model, target.name)}"
\`\`\`

Or build from a source checkout — the SDK is a plain scala-cli project:

\`\`\`bash
cd scala && scala-cli compile .
\`\`\`

`)
    return
  }

  // Publish pending: not yet on Maven Central. The generated SDK is a
  // dependency-free, plain-source scala-cli project (no sbt/mill build, no
  // third-party runtime deps), so install it from the git release tag or a
  // local source checkout and compile with scala-cli.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to Maven Central. The generated SDK is a
plain-source scala-cli project (no build tool, no third-party runtime
dependencies). Install it from the GitHub release tag
(\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) or from a source
checkout — compile it with scala-cli:

\`\`\`bash
cd scala && scala-cli compile .
\`\`\`

`)
})


export {
  ReadmeInstall
}
