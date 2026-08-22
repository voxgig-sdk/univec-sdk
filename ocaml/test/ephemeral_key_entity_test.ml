(* Generated ephemeral_key entity test. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

let () =
  test "ephemeral_key.entity_instance" (fun () ->
      let client = Sdk_client.test () in
      let ent = Sdk_client.ephemeral_key client Noval in
      check_str "name" ent.e_name "ephemeral_key")
