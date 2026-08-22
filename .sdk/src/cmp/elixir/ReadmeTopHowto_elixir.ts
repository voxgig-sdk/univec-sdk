
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeTopHowto = cmp(function ReadmeTopHowto(props: any) {
  const { ctx$: { model } } = props

  const Name = model.const.Name

  Content(`**Elixir:**
\`\`\`elixir
result = ${Name}.direct(sdk, ${Name}.Helpers.deep(%{
  "path" => "/api/resource/{id}",
  "method" => "GET",
  "params" => %{"id" => "example"}
}))
\`\`\`

`)

})


export {
  ReadmeTopHowto
}
