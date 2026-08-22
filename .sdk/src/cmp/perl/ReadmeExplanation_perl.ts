
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as hashrefs

The Perl SDK uses plain hashrefs and arrayrefs throughout rather than typed
objects. This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

Use \`${model.const.Name}Helpers::to_map()\` to safely validate that a value
is a hashref.

### Module structure

\`\`\`
${target.name}/
├── lib/${model.const.Name}SDK.pm    -- Main SDK module (package ${model.const.Name}SDK)
├── config.pm                    -- Configuration
├── features.pm                  -- Feature factory
├── core/                        -- Core types and context
├── entity/                      -- Entity implementations
├── feature/                     -- Built-in features (base, test, log)
├── utility/                     -- Utility functions
├── lib/Voxgig/Struct.pm         -- Vendored struct library
└── t/                           -- Test suites
\`\`\`

Load the main module with \`use lib 'lib'; use ${model.const.Name}SDK;\` — it
pulls in the config, features, and core modules for you. Require entity or
utility modules directly only when needed.

`)

})


export {
  ReadmeExplanation
}
