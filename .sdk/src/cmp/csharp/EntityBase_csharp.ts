
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
        __dirname + '/../../../src/cmp/csharp/fragment/EntityBase.fragment.cs'),

      replace: {
        ...props.ctx$.stdrep,
        ProjectNameSdk: model.const.Name + 'Sdk',
        ProjectName: model.const.Name,

        '#Entity-Hook': ({ name, indent }: any) =>
          Content({ indent }, `utility.FeatureHook(ctx, "${name}");
`),
      }
    })
  })
})


export {
  EntityBase
}
