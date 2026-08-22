
import { cmp, Content, isPublished, repoInfo, packageVersion } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  // Match the app atom in mix.exs: snake_case, since `:a-b` is not a valid atom.
  const app = model.const.name.toLowerCase().replace(/-/g, '_')

  if (isPublished(model, target.name)) {
    // Live on Hex: add the dependency to mix.exs deps/0.
    Content(`Add \`${app}\` to your \`mix.exs\` dependencies:

\`\`\`elixir
def deps do
  [
    {:${app}, "~> ${packageVersion(model, target.name)}"}
  ]
end
\`\`\`

Then fetch it:

\`\`\`bash
mix deps.get
\`\`\`

`)
    return
  }

  // Publish pending: not yet on Hex. Install from the git release tag or a
  // local path checkout.
  const { repoUrl, releasesUrl } = repoInfo(model)
  Content(`This package is not yet published to [Hex](https://hex.pm). Install it from
the GitHub release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl}))
by adding a git dependency to your \`mix.exs\`:

\`\`\`elixir
def deps do
  [
    {:${app}, git: "${repoUrl}.git", tag: "${target.name}/vX.Y.Z"}
  ]
end
\`\`\`

Or from a local source checkout:

\`\`\`elixir
def deps do
  [
    {:${app}, path: "../${model.const.name.toLowerCase()}-sdk/${target.name}"}
  ]
end
\`\`\`

Then run \`mix deps.get\`.

`)
})


export {
  ReadmeInstall
}
