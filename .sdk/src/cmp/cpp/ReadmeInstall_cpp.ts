
import { cmp, Content, repoInfo } from '@voxgig/sdkgen'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  // The C++ SDK is header-only: there is no package registry to install from.
  // Consumers vendor the source tree (or add it as a submodule) and put the
  // SDK directory on the compiler include path. The git release tag
  // (`cpp/vX.Y.Z`) is the unit of distribution.
  const { releasesUrl } = repoInfo(model)

  Content(`The ${target.title} SDK is **header-only** — there is no package to install
from a registry. Vendor the \`cpp/\` directory into your project (or add the
repository as a git submodule) and put it on your compiler's include path.
Releases are cut as the git tag \`${target.name}/vX.Y.Z\` (see
[Releases](${releasesUrl})).

\`\`\`bash
# Add the SDK as a submodule (or copy the cpp/ directory into your tree).
git submodule add <repo-url> third_party/${model.const.Name.toLowerCase()}-sdk
\`\`\`

Then include the umbrella header and compile with C++17:

\`\`\`cpp
#include "core/sdk.hpp"
\`\`\`

\`\`\`bash
g++ -std=c++17 -Ithird_party/${model.const.Name.toLowerCase()}-sdk/cpp your_app.cpp -o your_app
\`\`\`

`)
})


export {
  ReadmeInstall
}
