(* Univec SDK error (generated).
 *
 * The branded error type and its exception live in the runtime; this module
 * re-exports them so consumers have one import for error handling:
 *   try ... with Sdk_error.E err -> Printf.eprintf "%s\n" err.err_msg *)

open Sdk_types

type t = sdk_error

exception E = Sdk_error_exc

let code (e : t) : string = e.err_code
let message (e : t) : string = e.err_msg
