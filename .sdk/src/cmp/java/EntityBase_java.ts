
import * as Path from 'node:path'

import {
  Content,
  File,
  Folder,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


import { javaPackage } from './utility_java'


// Generates entity/EntityBase.java: the shared entity runtime (state,
// entity context, and the runOp pipeline). The `// #<Stage>-Hook` markers
// in the fragment become featureHook dispatch calls here.
const EntityBase = cmp(async function EntityBase(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const javapackage = javaPackage(model)

  Folder({ name: 'entity' }, () => {

    File({ name: 'EntityBase.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(
            __dirname + '/../../../src/cmp/java/fragment/EntityBase.fragment.java'),

          replace: {
            ...props.ctx$.stdrep,
            JAVAPACKAGE: javapackage,
            ProjectName: model.const.Name,

            '#Entity-Hook': ({ name, indent }: any) =>
              Content({ indent }, `utility.featureHook.apply(ctx, "${name}");`),
          }
        })
    })
  })
})


export {
  EntityBase
}
