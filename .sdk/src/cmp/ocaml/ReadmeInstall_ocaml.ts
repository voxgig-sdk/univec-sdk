
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or build from a source checkout — the SDK is dependency-free and compiles
with the stock \`ocamlc\` (no opam packages, no dune):

\`\`\`bash
cd ${target.name} && make build
\`\`\`

`)
    return
  }

  // Publish pending: not yet on the opam registry. Build from the git release
  // tag or from a local source checkout. The generated library is
  // dependency-free — a plain `make build` (stock `ocamlc`) is all it needs.
  const { releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to the opam registry. Install it from the
GitHub release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl}))
or from a source checkout. The SDK is dependency-free and compiles with the
stock \`ocamlc\` — no opam packages, no dune:

\`\`\`bash
cd ${target.name} && make build
\`\`\`

`)
})


export {
  ReadmeInstall
}
