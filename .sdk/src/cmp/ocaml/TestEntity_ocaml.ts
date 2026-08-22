
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'

import { ocamlString, ocamlVarName } from './utility_ocaml'


// Generated per-entity test: the accessor yields an entity with the right
// name, and (test mode) the present read ops round-trip through the full
// pipeline against seeded mock data (list returns the seeded record; load by
// id returns it). Mirrors the intent of the rust/go TestEntity flow, but
// self-contained (inline seed, no external fixture).
const TestEntity = cmp(function TestEntity(props: any) {
  const { target, entity } = props

  const fn = ocamlVarName(entity.name)
  const opnames = Object.keys(entity.op || {})
  const hasList = opnames.includes('list')
  const hasLoad = opnames.includes('load')
  const hasId = null != entity.id
  const id = entity.name + '01'

  File({ name: entity.name + '_entity_test.' + target.ext }, () => {

    Content(`(* Generated ${entity.name} entity test. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

let () =
  test "${ocamlString(entity.name)}.entity_instance" (fun () ->
      let client = Sdk_client.test () in
      let ent = Sdk_client.${fn} client Noval in
      check_str "name" ent.e_name "${ocamlString(entity.name)}")
`)

    // Seeded test-mode round-trip: the test feature builds an in-memory mock
    // from options.entity, so a seeded record is loadable/listable.
    if (hasList || hasLoad) {
      Content(`
let () =
  test "${ocamlString(entity.name)}.seeded_ops" (fun () ->
      let record = jo [("id", Str "${ocamlString(id)}")] in
      let seed = jo [("${ocamlString(entity.name)}",
                      jo [("${ocamlString(id)}", record)])] in
      let client = Sdk_client.test_with (jo [("entity", seed)]) Noval in
      let ent = Sdk_client.${fn} client Noval in
      ignore ent;
`)
      if (hasList) {
        Content(`      (* The op resolves to one ENTITY per record; the record is reached
         with e_data_get. See AGENTS.md "Entity operations return ENTITIES". *)
      let listed = ent.e_list (empty_map ()) Noval in
      check_int "list size" (List.length listed) 1;
      List.iter (fun en -> check "list entry data is a map" (ismap (en.e_data_get ()))) listed;
`)
      }
      if (hasLoad) {
        Content(`      let loaded = ent.e_load (jo [("id", Str "${ocamlString(id)}")]) Noval in
      let loaded_data = loaded.e_data_get () in
      check "load data is a map" (ismap loaded_data);
`)
        if (hasId) {
          Content(`      check_vstr "load id" (getp loaded_data "id") "${ocamlString(id)}";
`)
        }
      }
      Content(`      ())
`)
    }

    // PR review #4: entity e_stream(action, args, callopts) runs the op through
    // the full pipeline and returns a lazy Seq. Fallback (no streaming feature)
    // yields the materialised items; with the streaming feature active it yields
    // from the streaming iterator (chunkSize groups into batches). Needs a list
    // op with seeded data.
    if (hasList) {
      Content(`
let () =
  test "${ocamlString(entity.name)}.stream" (fun () ->
      let mk_seed () =
        jo [("${ocamlString(entity.name)}",
             jo [("S1", jo [("id", Str "S1"); ("name", Str "a")]);
                 ("S2", jo [("id", Str "S2"); ("name", Str "b")]);
                 ("S3", jo [("id", Str "S3"); ("name", Str "c")])])] in
      let has_streaming =
        not (is_nullish (getp (getp (Sdk_config.make_config ()) "feature") "streaming")) in

      (* Fallback (no streaming feature): materialised items. *)
      let client = Sdk_client.test_with (jo [("entity", mk_seed ())]) Noval in
      let ent = Sdk_client.${fn} client Noval in
      let items = List.of_seq (ent.e_stream "list" (empty_map ()) Noval) in
      check_int "stream fallback count" (List.length items) 3;
      check "stream yields record maps" (ismap (List.hd items));

      (* signal cancels iteration between yields. *)
      let client2 = Sdk_client.test_with (jo [("entity", mk_seed ())]) Noval in
      let ent2 = Sdk_client.${fn} client2 Noval in
      let n = ref 0 in
      let sig_ = vfunc0 (fun () -> incr n; Bool (!n >= 2)) in
      let items2 = List.of_seq (ent2.e_stream "list" (empty_map ()) (jo [("signal", sig_)])) in
      check_int "stream signal stops after first" (List.length items2) 1;

      if has_streaming then begin
        (* Streaming feature active: yields from the streaming iterator. *)
        let sfeat = jo [("feature", jo [("streaming", jo [("active", Bool true)])])] in
        let sclient = Sdk_client.test_with (jo [("entity", mk_seed ())]) sfeat in
        let sent = Sdk_client.${fn} sclient Noval in
        check_int "stream (streaming active) count"
          (List.length (List.of_seq (sent.e_stream "list" (empty_map ()) Noval))) 3;

        (* chunkSize groups items into batches: 3 items / 2 -> 2 batches. *)
        let cfeat = jo [("feature", jo [("streaming",
                          jo [("active", Bool true); ("chunkSize", Num 2.)])])] in
        let cclient = Sdk_client.test_with (jo [("entity", mk_seed ())]) cfeat in
        let cent = Sdk_client.${fn} cclient Noval in
        check_int "stream chunkSize batch count"
          (List.length (List.of_seq (cent.e_stream "list" (empty_map ()) Noval))) 2
      end)
`)
    }
  })
})


export {
  TestEntity
}
