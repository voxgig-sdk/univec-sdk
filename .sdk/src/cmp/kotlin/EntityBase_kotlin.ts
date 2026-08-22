
import * as Path from 'node:path'

import {
  Content,
  File,
  Folder,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


import { kotlinPackage } from './utility_kotlin'


// Generates entity/EntityBase.kt: the shared entity runtime (state, entity
// context, and the runOp pipeline). The `// #<Stage>-Hook` markers in the
// fragment become featureHook dispatch calls here.
const EntityBase = cmp(async function EntityBase(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const kotlinpackage = kotlinPackage(model)

  Folder({ name: 'entity' }, () => {

    File({ name: 'EntityBase.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(
            __dirname + '/../../../src/cmp/kotlin/fragment/EntityBase.fragment.kt'),

          replace: {
            ...props.ctx$.stdrep,
            KOTLINPACKAGE: kotlinpackage,
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
