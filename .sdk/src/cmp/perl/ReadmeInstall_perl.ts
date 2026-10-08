
import { cmp, Content, installCommand, isPublished, repoInfo } from '@voxgig/sdkgen'

import { minPerl, perlVersionLabel } from './utility_perl'


const ReadmeInstall = cmp(function ReadmeInstall(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  Content(`The SDK needs perl ${perlVersionLabel(minPerl(model, target))} or later.

`)

  if (isPublished(model, target.name)) {
    Content(`\`\`\`bash
${installCommand(model, target.name)}
\`\`\`

Or install the \`${model.const.Name}SDK\` distribution from a source
checkout with cpanminus:

\`\`\`bash
cpanm .
\`\`\`

`)
    return
  }

  // Publish pending: not yet on CPAN. This is a pure-Perl SDK with zero
  // non-core runtime deps, so the simplest install is to add the SDK's
  // \`lib\` directory to Perl's module search path (\`@INC\`).
  const { hostName, tagsUrl } = repoInfo(model)
  Content(`This package is not yet published to CPAN. Install it from the ${hostName}
release tag (\`${target.name}/vX.Y.Z\`, see [Tags](${tagsUrl})) or
from a source checkout.

The SDK is pure Perl with zero non-core runtime dependencies, so no build
step is required — just put its \`lib\` directory on \`@INC\`:

\`\`\`perl
use lib 'lib';
use ${model.const.Name}SDK;
\`\`\`

`)
})


export {
  ReadmeInstall
}
