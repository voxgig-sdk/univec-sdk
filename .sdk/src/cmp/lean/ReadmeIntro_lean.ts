import { cmp, Content } from '@voxgig/sdkgen'
import { KIT, getModelPath } from '@voxgig/apidef'

const ReadmeIntro = cmp(function ReadmeIntro(props: any) {
  const { target, ctx$: { model } } = props
  const info = (model.main && model.main.kit && model.main.kit.info) || {}
  const tagline = info.tagline || ''

  Content(`# ${model.Name} ${target.title} SDK

${tagline}

The ${target.title} SDK for the ${model.Name} API — an entity-oriented client
for Lean 4. The API is surfaced as capitalised Entities with a small, uniform
verb set (\`list\`, \`load\`, \`create\`, \`update\`, \`remove\`); every operation is
driven by the embedded config through the dependency-free vendored voxgig
\`Value\` struct model, and runs in struct's \`SIO\` monad.

`)

  // touch the model so a mis-shaped model surfaces here, not at render time.
  getModelPath(model, `main.${KIT}.entity`)
})

export { ReadmeIntro }
