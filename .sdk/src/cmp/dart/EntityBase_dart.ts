
import * as Path from 'node:path'

import {
  cmp,
  File, Fragment,
} from '@voxgig/sdkgen'



const EntityBase = cmp(async function EntityBase(props: any) {

  // Needs type: target object
  const { target } = props
  const { model } = props.ctx$

  File({ name: model.const.Name + 'EntityBase.' + target.ext }, () => {

    Fragment(
      {
        from:
          Path.normalize(__dirname + '/../../../src/cmp/dart/fragment/EntityBase.fragment.dart'),

        replace: {
          ...props.ctx$.stdrep,
        }
      })
  })
})


export {
  EntityBase
}
