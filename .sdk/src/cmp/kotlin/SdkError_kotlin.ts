
import * as Path from 'node:path'


import {
  File,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import { kotlinPackage } from './utility_kotlin'


// Generates core/SdkError.kt. The class name is fixed (templates reference the
// error type), but the `sdk` marker field carries the project name.
const SdkError = cmp(async function SdkError(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const kotlinpackage = kotlinPackage(model)

  const ff = Path.normalize(__dirname + '/../../../src/cmp/kotlin/fragment/')

  File({ name: 'SdkError.' + target.ext }, () => {

    Fragment({
      from: ff + 'SdkError.fragment.kt',

      replace: {
        ...ctx$.stdrep,
        KOTLINPACKAGE: kotlinpackage,
        ProjectName: model.const.Name,
      }
    })
  })
})


export {
  SdkError
}
