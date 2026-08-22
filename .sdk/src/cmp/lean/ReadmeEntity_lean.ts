import { cmp, Content, each } from '@voxgig/sdkgen'

// One section per entity: its op namespace and the verbs it supports.
const ReadmeEntity = cmp(function ReadmeEntity(props: any) {
  const { entity } = props
  if (null == entity) return
  const ns = entity.name.charAt(0).toUpperCase() + entity.name.slice(1)
  const ops = Object.keys(entity.op || {}).sort()
  if (0 === ops.length) return

  let rows = ''
  for (const op of ops) {
    const call =
      'create' === op ? `${ns}.create sdk data (← emptyMap)`
        : 'update' === op ? `${ns}.update sdk match data (← emptyMap)`
          : `${ns}.${op} sdk match (← emptyMap)`
    rows += `| \`${op}\` | \`${call}\` |\n`
  }

  Content(`Operations are in the \`${ns}\` namespace; each takes the client first
and per-call options last.

| Op | Call |
| --- | --- |
${rows}
`)
})

export { ReadmeEntity }
