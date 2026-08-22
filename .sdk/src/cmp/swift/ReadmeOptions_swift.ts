
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

  Content(`\`\`\`swift
let options = VMap()
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`options.entries["${option.name}"] = .string(
    ProcessInfo.processInfo.environment["${envName(model)}_APIKEY"] ?? "")
`)
    }
    else {
      Content(`// options.entries["${option.name}"] = ${option.kind === 'string' ? '.string("...")' : '/* ... */'}
`)
    }
  })

  Content(`let client = ${SDK}(options)
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
