
import * as Path from 'node:path'


import {
  Content,
  File,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


const EntityBase = cmp(async function EntityBase(props: any) {
  const { target } = props
  const { model } = props.ctx$

  File({ name: model.const.Name + 'EntityBase.' + target.ext }, () => {

    Fragment({
      from: Path.normalize(
        __dirname + '/../../../src/cmp/swift/fragment/EntityBase.fragment.swift'),

      replace: {
        ...props.ctx$.stdrep,
        ProjectName: model.const.Name,

        '#Entity-Hook': ({ name, indent }: any) =>
          Content({ indent }, `utility.featureHook(ctx, "${name}")
`),
      }
    })
  })
})


export {
  EntityBase
}
