
import { cmp, each, Content, envName, isAuthActive } from '@voxgig/sdkgen'


const ReadmeOptions = cmp(function ReadmeOptions(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const publishedOptions = each(target.options).filter((option: any) =>
    option.publish && ('apikey' !== option.name || isAuthActive(model)))
  if (0 === publishedOptions.length) {
    return
  }

  Content(`

## Options

Pass an options map when creating a client instance:

`)

  Content(`\`\`\`rust
let client = ${model.Name}SDK::new(jo(vec![
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`    ("${option.name}", Value::str(std::env::var("${envName(model)}_APIKEY").unwrap_or_default())),
`)
    }
    else {
      const val = option.kind === 'string' ? 'Value::str("...")' : 'Value::Noval'
      Content(`    // ("${option.name}", ${val}),
`)
    }
  })

  Content(`]));
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
