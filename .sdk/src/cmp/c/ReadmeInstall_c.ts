
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or build it from a source checkout with the bundled \`Makefile\`:

\`\`\`bash
cd ${target.name} && make
\`\`\`

`)
    return
  }

  // Publish pending: C has no central package registry — the release IS the
  // git tag. Build from a source checkout (the vendored voxgig struct means
  // there are no external dependencies to fetch).
  const { releasesUrl } = repoInfo(model)
  Content(`C has no central package registry — a release is the git tag
(\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})). Build from a
source checkout with the bundled \`Makefile\`; the voxgig struct library is
vendored under \`utility/struct\`, so there are no external dependencies to
fetch:

\`\`\`bash
cd ${target.name} && make          # builds libsdk.a
cd ${target.name} && make test     # builds + runs the test binaries
\`\`\`

Link your program against \`libsdk.a\` and include \`core/api.h\`:

\`\`\`bash
cc -I ${target.name}/core -I ${target.name}/utility/struct \\
   myapp.c ${target.name}/libsdk.a -lm -o myapp
\`\`\`

`)
})


export {
  ReadmeInstall
}
