
import * as Path from 'node:path'

import {
  Content,
  File,
  Folder,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


import { scalaPackage } from './utility_scala'


// Generates entity/EntityBase.scala: the shared entity runtime (state,
// entity context, and the runOp pipeline). The `// #<Stage>-Hook` markers in
// the fragment become featureHook dispatch calls here.
const EntityBase = cmp(async function EntityBase(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const scalapackage = scalaPackage(model)

  Folder({ name: 'entity' }, () => {

    File({ name: 'EntityBase.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(
            __dirname + '/../../../src/cmp/scala/fragment/EntityBase.fragment.scala'),

          replace: {
            ...props.ctx$.stdrep,
            SCALAPACKAGE: scalapackage,
            ProjectName: model.const.Name,

            '#Entity-Hook': ({ name, indent }: any) =>
              Content({ indent }, `utility.featureHook(ctx, "${name}")`),
          }
        })
    })
  })
})


export {
  EntityBase
}
