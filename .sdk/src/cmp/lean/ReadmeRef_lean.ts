import { cmp, Content, File, ReadmeRefFeatures } from '@voxgig/sdkgen'


// Lean emitted no REFERENCE.md at all. Every other per-language ReadmeRef
// opens the File itself; this one only called Content(), so its module table
// was written into no file and dropped, and lean was the one target shipping
// no reference. Opening the File fixes that and gives the shared feature
// reference somewhere to land.
const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## Modules

| Module | Purpose |
| --- | --- |
| \`SdkClient\` | \`Sdk.newSdk\` / \`Sdk.testSdk\` and the per-entity op namespaces |
| \`SdkConfig\` | the embedded API model (JSON) |
| \`SdkRuntime\` | the config-driven operation pipeline and curl transport |
| \`SdkUtility\` | request-shaping utilities (spec, url, params, transforms, result) |
| \`SdkJson\` | JSON text to struct \`Value\` |
| \`VoxgigStruct\` | the vendored voxgig struct value model |


## Features

`)

    ReadmeRefFeatures({ target })
  })
})

export { ReadmeRef }
