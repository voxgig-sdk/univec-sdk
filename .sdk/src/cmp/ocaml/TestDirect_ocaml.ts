
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'

import { ocamlString } from './utility_ocaml'


// Generated per-entity direct-call test: a mock system.fetch records calls and
// returns a canned response; client.direct issues the raw request and parses
// the JSON body (mirrors the rust/go TestDirect unit path).
const TestDirect = cmp(function TestDirect(props: any) {
  const { target, entity } = props

  File({ name: entity.name + '_direct_test.' + target.ext }, () => {

    Content(`(* Generated ${entity.name} direct-call test. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

let () =
  test "${ocamlString(entity.name)}.direct_call" (fun () ->
      let calls = ref [] in
      let mock = Func (fun _ args _ _ ->
          calls := !calls @ [args];
          jo [("status", Num 200.); ("statusText", Str "OK"); ("headers", empty_map ());
              ("json", json_thunk (jo [("id", Str "direct01")]))]) in
      let client = Sdk_client.make
          (jo [("base", Str "http://localhost:8080"); ("system", jo [("fetch", mock)])]) in
      let result = Sdk_client.direct client
          (jo [("path", Str "/${ocamlString(entity.name)}"); ("method", Str "GET")]) in
      check_vbool "ok" (getp result "ok") true;
      check_vstr "data.id" (getp (getp result "data") "id") "direct01";
      check_int "one call" (List.length !calls) 1)
`)
  })
})


export {
  TestDirect
}
