
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

Pass options as a \`voxgig.struct\` map when creating a client:

`)

  Content(`\`\`\`clojure
(def client
  (api/make-sdk
    (vs/jm
`)

  publishedOptions.map((option: any) => {
    if ('apikey' === option.name) {
      Content(`      "${option.name}" (System/getenv "${envName(model)}_APIKEY")
`)
    }
    else {
      Content(`      ;; "${option.name}" ${option.kind === 'string' ? '"..."' : '...'}
`)
    }
  })

  Content(`      )))
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
