
import { cmp, Content, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content('```js')
    Content(`
npm install ${target.module.name}
`)
    Content('```')
    return
  }

  // Publish pending, as in the ts target: a tag may not exist, so a clone is
  // always offered. The js target needs no build.
  const { hostName, tagsUrl, repoUrl, repo } = repoInfo(model)
  Content(`This package is not yet published to npm. Install it from the ${hostName}
release tag (\`${target.name}/vX.Y.Z\`, see [Tags](${tagsUrl})), or from a
clone:

\`\`\`bash
git clone ${repoUrl}
npm install ./${repo}/${target.name}
\`\`\`

`)
})


export {
  ReadmeInstall
}
