(* Generated embed entity test. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

let () =
  test "embed.entity_instance" (fun () ->
      let client = Sdk_client.test () in
      let ent = Sdk_client.embed client Noval in
      check_str "name" ent.e_name "embed")
