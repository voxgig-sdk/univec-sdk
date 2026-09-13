
import { cmp, each, Content, envName, isAuthActive } from '@voxgig/sdkgen'


const ReadmeOptions = cmp(function ReadmeOptions(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const publishedOptions = each(target.options).filter((option: any) =>
    option.publish && ('apikey' !== option.name || isAuthActive(model)))
  if (0 === publishedOptions.length) {
    return
  }

  const authActive = isAuthActive(model)

  Content(`

## Options

Pass an options \`Value\` (built with \`jo\`) when constructing a client. Any
option may be omitted; the entries below are illustrative.

`)

  if (authActive) {
    Content(`\`\`\`haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

makeClient :: IO Sdk.Client
makeClient = do
  -- Read the API key from the ${envName(model)}_APIKEY environment variable.
  opts <- jo [("apikey", VStr "your-api-key")]
  Sdk.newSdk opts
\`\`\`

`)
  }
  else {
    Content(`\`\`\`haskell
import qualified SdkClient as Sdk
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

makeClient :: IO Sdk.Client
makeClient = do
  opts <- jo [("base", VStr "https://api.example.com")]
  Sdk.newSdk opts
\`\`\`

`)
  }

  Content(`Every published option:

| Option | Type | Description |
| --- | --- | --- |
`)

  publishedOptions.map((option: any) => {
    Content(`| \`${option.name}\` | \`${option.kind}\` | ${option.short} |
`)
  })

  Content(`
`)
})


export {
  ReadmeOptions
}
