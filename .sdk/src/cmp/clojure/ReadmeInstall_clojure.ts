
import { cmp, Content, isPublished, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$
  const { origin, repo, repoUrl, releasesUrl } = repoInfo(model)

  if (isPublished(model, target.name)) {
    // Live on Clojars: add the published coordinate to deps.edn.
    Content(`Add the dependency to your \`deps.edn\`:

\`\`\`clojure
;; deps.edn
{:deps {org.clojars.${origin}/${repo} {:mvn/version "X.Y.Z"}}}
\`\`\`

`)
    return
  }

  // Publish pending: not yet on Clojars. Depend on the library directly from
  // the GitHub release tag, or from a local checkout via :local/root.
  Content(`This package is not yet published to Clojars. Depend on it directly from the
GitHub release tag (\`${target.name}/vX.Y.Z\`, see [Releases](${releasesUrl})),
using a \`tools.deps\` git dependency:

\`\`\`clojure
;; deps.edn
{:deps {${model.const.Name.toLowerCase()}/sdk
        {:git/url "${repoUrl}"
         :git/tag "${target.name}/vX.Y.Z"
         :git/sha "..."
         :deps/root "${target.name}"}}}
\`\`\`

Or from a local source checkout:

\`\`\`clojure
;; deps.edn
{:deps {${model.const.Name.toLowerCase()}/sdk {:local/root "../${target.name}"}}}
\`\`\`

`)
})


export {
  ReadmeInstall
}
