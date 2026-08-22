
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

Pass options as an \`sdk::Value\` map when constructing a client:

`)

  const hasApikey = publishedOptions.some((o: any) => 'apikey' === o.name)

  Content(`\`\`\`cpp
${hasApikey ? `const char* apikey = std::getenv("${envName(model)}_APIKEY");
` : ''}auto client = std::make_shared<${model.Name}SDK>(vmap({
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`    {"${option.name}", Value(apikey ? apikey : "")},
`)
    }
    else {
      Content(`    // {"${option.name}", ${option.kind === 'string' ? 'Value("...")' : 'Value(...)'}},
`)
    }
  })

  Content(`}));
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
