
import * as Path from 'node:path'


import {
  File,
  Fragment,
  cmp,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


// core/error.rs — the branded SDK error type, generated from the SdkError
// fragment (twin of SdkError_ts; go keeps this in a template instead).
const SdkError = cmp(async function SdkError(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const ff = Path.normalize(__dirname + '/../../../src/cmp/rust/fragment/')

  File({ name: 'error.' + target.ext }, () => {

    Fragment({
      from: ff + 'SdkError.fragment.rs',

      replace: {
        ...ctx$.stdrep,
      }
    })
  })
})


export {
  SdkError
}
