
import { cmp, each, Content, envName, isAuthActive } from '@voxgig/sdkgen'


const ReadmeOptions = cmp(function ReadmeOptions(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const Name = model.const.Name

  const publishedOptions = each(target.options).filter((option: any) =>
    option.publish && ('apikey' !== option.name || isAuthActive(model)))
  if (0 === publishedOptions.length) {
    return
  }

  Content(`

## Options

Pass options when creating a client. Native maps are lifted into the SDK's
value model by \`${Name}.Helpers.deep/1\`:

`)

  Content(`\`\`\`elixir
sdk = ${Name}.new(${Name}.Helpers.deep(%{
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`  "${option.name}" => System.get_env("${envName(model)}_APIKEY"),
`)
    }
    else {
      Content(`  # "${option.name}" => ${option.kind === 'string' ? "\"...\"" : '...'},
`)
    }
  })

  Content(`}))
\`\`\`

`)

  Content(`| Option | Type | Description |
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
