
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

  Content(`\`\`\`zig
const client = sdk.${model.Name}SDK.new(h.jo(&.{
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`    .{ "${option.name}", h.vstr(std.posix.getenv("${envName(model)}_APIKEY") orelse "") },
`)
    }
    else {
      const val = option.kind === 'string' ? 'h.vstr("...")' : 'h.vnull()'
      Content(`    // .{ "${option.name}", ${val} },
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
