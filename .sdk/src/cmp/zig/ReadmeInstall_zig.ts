
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or build it from a source checkout:

\`\`\`bash
cd ${target.name} && zig build
\`\`\`

`)
    return
  }

  // Zig has no central package registry — the release IS the git tag. Depend
  // on it via the Zig package manager (a git-tagged url in build.zig.zon) or
  // build from a local source checkout.
  const { releasesUrl } = repoInfo(model)
  Content(`Zig has no central package registry, so this package is distributed as a
git tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})). Add it to
your \`build.zig.zon\` dependencies, or build from a source checkout:

\`\`\`bash
cd ${target.name} && zig build
\`\`\`

To depend on it from another project, add the tagged archive to
\`build.zig.zon\`:

\`\`\`zig
.dependencies = .{
    .sdk = .{
        .url = "<repo-url>/archive/refs/tags/${target.name}/vX.Y.Z.tar.gz",
        // .hash = "...", // filled in by \`zig fetch\`
    },
},
\`\`\`

`)
})


export {
  ReadmeInstall
}
