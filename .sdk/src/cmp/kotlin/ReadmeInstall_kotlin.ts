
import { cmp, Content, isPublished, repoInfo, packageVersion } from '@voxgig/sdkgen'

import { gradleGroup } from './utility_kotlin'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  const group = gradleGroup(model)
  const artifactId = `${model.name}-sdk`

  if (isPublished(model, target.name)) {
    Content(`Add the dependency to your \`build.gradle.kts\`:

\`\`\`kotlin
dependencies {
    implementation("${group}:${artifactId}:${packageVersion(model, target.name)}")
}
\`\`\`

Or build and install from a source checkout:

\`\`\`bash
cd kotlin && gradle build
\`\`\`

`)
    return
  }

  // Publish pending: not yet on Maven Central. Install from the git release
  // tag or from a local source checkout built with Gradle.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to Maven Central. Install it from the GitHub
release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) or
from a source checkout — build the library with Gradle:

\`\`\`bash
cd kotlin && gradle build
\`\`\`

`)
})


export {
  ReadmeInstall
}
