(* Generated model entity test. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

let () =
  test "model.entity_instance" (fun () ->
      let client = Sdk_client.test () in
      let ent = Sdk_client.model client Noval in
      check_str "name" ent.e_name "model")

let () =
  test "model.seeded_ops" (fun () ->
      let record = jo [("id", Str "model01")] in
      let seed = jo [("model",
                      jo [("model01", record)])] in
      let client = Sdk_client.test_with (jo [("entity", seed)]) Noval in
      let ent = Sdk_client.model client Noval in
      ignore ent;
      (* The op resolves to one ENTITY per record; the record is reached
         with e_data_get. See AGENTS.md "Entity operations return ENTITIES". *)
      let listed = ent.e_list (empty_map ()) Noval in
      check_int "list size" (List.length listed) 1;
      List.iter (fun en -> check "list entry data is a map" (ismap (en.e_data_get ()))) listed;
      ())

let () =
  test "model.stream" (fun () ->
      let mk_seed () =
        jo [("model",
             jo [("S1", jo [("id", Str "S1"); ("name", Str "a")]);
                 ("S2", jo [("id", Str "S2"); ("name", Str "b")]);
                 ("S3", jo [("id", Str "S3"); ("name", Str "c")])])] in
      let has_streaming =
        not (is_nullish (getp (getp (Sdk_config.make_config ()) "feature") "streaming")) in

      (* Fallback (no streaming feature): materialised items. *)
      let client = Sdk_client.test_with (jo [("entity", mk_seed ())]) Noval in
      let ent = Sdk_client.model client Noval in
      let items = List.of_seq (ent.e_stream "list" (empty_map ()) Noval) in
      check_int "stream fallback count" (List.length items) 3;
      check "stream yields record maps" (ismap (List.hd items));

      (* signal cancels iteration between yields. *)
      let client2 = Sdk_client.test_with (jo [("entity", mk_seed ())]) Noval in
      let ent2 = Sdk_client.model client2 Noval in
      let n = ref 0 in
      let sig_ = vfunc0 (fun () -> incr n; Bool (!n >= 2)) in
      let items2 = List.of_seq (ent2.e_stream "list" (empty_map ()) (jo [("signal", sig_)])) in
      check_int "stream signal stops after first" (List.length items2) 1;

      if has_streaming then begin
        (* Streaming feature active: yields from the streaming iterator. *)
        let sfeat = jo [("feature", jo [("streaming", jo [("active", Bool true)])])] in
        let sclient = Sdk_client.test_with (jo [("entity", mk_seed ())]) sfeat in
        let sent = Sdk_client.model sclient Noval in
        check_int "stream (streaming active) count"
          (List.length (List.of_seq (sent.e_stream "list" (empty_map ()) Noval))) 3;

        (* chunkSize groups items into batches: 3 items / 2 -> 2 batches. *)
        let cfeat = jo [("feature", jo [("streaming",
                          jo [("active", Bool true); ("chunkSize", Num 2.)])])] in
        let cclient = Sdk_client.test_with (jo [("entity", mk_seed ())]) cfeat in
        let cent = Sdk_client.model cclient Noval in
        check_int "stream chunkSize batch count"
          (List.length (List.of_seq (cent.e_stream "list" (empty_map ()) Noval))) 2
      end)
