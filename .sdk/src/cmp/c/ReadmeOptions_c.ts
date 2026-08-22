
import { cmp, each, Content, envName, isAuthActive } from '@voxgig/sdkgen'

import { cIdent } from './utility_c'


const ReadmeOptions = cmp(function ReadmeOptions(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const ident = cIdent(model)

  const publishedOptions = each(target.options).filter((option: any) =>
    option.publish && ('apikey' !== option.name || isAuthActive(model)))
  if (0 === publishedOptions.length) {
    return
  }

  Content(`

## Options

Pass an options map (a \`voxgig_value*\`) when creating a client instance:

`)

  Content(`\`\`\`c
voxgig_value* opts = cmap(${publishedOptions.length},
`)

  publishedOptions.map((option: any, i: number) => {
    const comma = i < publishedOptions.length - 1 ? ',' : ');'
    if ('apikey' === option.name) {
      Content(`  "${option.name}", v_str(getenv("${envName(model)}_APIKEY"))${comma}
`)
    }
    else {
      const val = option.kind === 'string' ? 'v_str("...")' : 'v_null()'
      Content(`  "${option.name}", ${val}${comma}
`)
    }
  })

  Content(`${model.const.Name}SDK* client = ${ident}_sdk_new(opts);
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
