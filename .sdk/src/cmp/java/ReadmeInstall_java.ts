
import { cmp, Content, isPublished, repoInfo, packageVersion } from '@voxgig/sdkgen'

import { mavenGroupId } from './utility_java'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  const groupId = mavenGroupId(model)
  const artifactId = `${model.name}-sdk`

  if (isPublished(model, target.name)) {
    Content(`Add the dependency to your \`pom.xml\`:

\`\`\`xml
<dependency>
  <groupId>${groupId}</groupId>
  <artifactId>${artifactId}</artifactId>
  <version>${packageVersion(model, target.name)}</version>
</dependency>
\`\`\`

Or build and install from a source checkout:

\`\`\`bash
cd java && mvn install
\`\`\`

`)
    return
  }

  // Publish pending: not yet on Maven Central. Install from the git release
  // tag or from a local source checkout built with Maven.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to Maven Central. Install it from the GitHub
release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) or
from a source checkout — build the library with Maven:

\`\`\`bash
cd java && mvn install
\`\`\`

`)
})


export {
  ReadmeInstall
}
