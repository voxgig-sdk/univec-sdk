
import { cmp, each, Content, envName, isAuthActive } from '@voxgig/sdkgen'


const ReadmeOptions = cmp(function ReadmeOptions(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const SDK = model.const.Name + 'SDK'

  const publishedOptions = each(target.options).filter((option: any) =>
    option.publish && ('apikey' !== option.name || isAuthActive(model)))
  if (0 === publishedOptions.length) {
    return
  }

  Content(`

## Options

Pass options when creating a client instance:

`)

  Content(`\`\`\`java
Map<String, Object> options = new java.util.LinkedHashMap<>();
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`options.put("${option.name}", System.getenv("${envName(model)}_APIKEY"));
`)
    }
    else {
      Content(`// options.put("${option.name}", ${option.kind === 'string' ? "\"...\"" : '...'});
`)
    }
  })

  Content(`${SDK} client = new ${SDK}(options);
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
