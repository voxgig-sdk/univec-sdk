

import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


// sdk_error.ml — a thin API-facing view of the branded SDK error. The error
// type and exception themselves live in the runtime (Sdk_types.sdk_error /
// Sdk_error_exc); this module re-exports them under stable names so callers
// have a single place to catch/inspect errors (twin of rust core/error.rs).
const SdkError = cmp(async function SdkError(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model = ctx$.model

  File({ name: 'sdk_error.' + target.ext }, () => {
    Content(`(* ${model.const.Name} SDK error (generated).
 *
 * The branded error type and its exception live in the runtime; this module
 * re-exports them so consumers have one import for error handling:
 *   try ... with Sdk_error.E err -> Printf.eprintf "%s\\n" err.err_msg *)

open Sdk_types

type t = sdk_error

exception E = Sdk_error_exc

let code (e : t) : string = e.err_code
let message (e : t) : string = e.err_msg
`)
  })
})


export {
  SdkError
}
