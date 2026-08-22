import { cmp, Content } from '@voxgig/sdkgen'

const ReadmeRef = cmp(function ReadmeRef(_props: any) {
  Content(`| Module | Purpose |
| --- | --- |
| \`SdkClient\` | \`Sdk.newSdk\` / \`Sdk.testSdk\` and the per-entity op namespaces |
| \`SdkConfig\` | the embedded API model (JSON) |
| \`SdkRuntime\` | the config-driven operation pipeline and curl transport |
| \`SdkUtility\` | request-shaping utilities (spec, url, params, transforms, result) |
| \`SdkJson\` | JSON text to struct \`Value\` |
| \`VoxgigStruct\` | the vendored voxgig struct value model |

`)
})

export { ReadmeRef }
