
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or add a project reference to a source checkout:

\`\`\`bash
dotnet add reference ../${model.const.Name}SDK/${model.const.Name}SDK.csproj
\`\`\`

`)
    return
  }

  // Publish pending: not yet on NuGet. Install from the git release tag or
  // from a local source checkout.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to NuGet. Install it from the GitHub
release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})) or
from a source checkout — build the library and add a project reference:

\`\`\`bash
cd csharp && dotnet build ${model.const.Name}SDK.csproj
\`\`\`

`)
})


export {
  ReadmeInstall
}
