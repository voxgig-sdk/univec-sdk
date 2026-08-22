
import * as Path from 'node:path'


import {
  File,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import { javaPackage } from './utility_java'


// Generates core/SdkError.java. The class name is fixed (Java file names
// must match public class names, and templates reference the error type),
// but the `sdk` marker field carries the project name.
const SdkError = cmp(async function SdkError(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const javapackage = javaPackage(model)

  const ff = Path.normalize(__dirname + '/../../../src/cmp/java/fragment/')

  File({ name: 'SdkError.' + target.ext }, () => {

    Fragment({
      from: ff + 'SdkError.fragment.java',

      replace: {
        ...ctx$.stdrep,
        JAVAPACKAGE: javapackage,
        ProjectName: model.const.Name,
      }
    })
  })
})


export {
  SdkError
}
