
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeTopHowto = cmp(function ReadmeTopHowto(props: any) {
  const { target } = props

  Content(`**Haskell:**
\`\`\`haskell
import qualified SdkClient as Sdk
import qualified SdkFeatures as F
import VoxgigStruct (Value (..))
import SdkHelpers (jo)

main :: IO ()
main = do
  sdk <- Sdk.newSdk0
  params <- jo [("id", VStr "example")]
  args <- jo [("path", VStr "/api/resource/{id}"), ("method", VStr "GET"), ("params", params)]
  result <- F.direct sdk args
  print result
\`\`\`

`)

})


export {
  ReadmeTopHowto
}
