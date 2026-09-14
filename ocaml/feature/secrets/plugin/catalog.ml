(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/catalog.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The definition catalog (§10.1).

   A definition is registered once and may back many instances. Option
   shapes are validated AT REGISTRATION, not when a document happens to
   exercise a key — so a malformed shape fails once, and in the same
   place everywhere (§9.4). `declare/shape` pins that timing. *)

module V = Value
open Defs

let makecatalog () = { defs = [] }

let add c def =
  if not (Ref.checkname (V.vstr def.dname)) then
    Types.fail "plugin_definition_name"
      ("invalid definition name: " ^ def.dname);

  (* Validate the shape HERE. Deferring it to resolution time means a
     malformed shape surfaces at a different moment in every host that
     loads it, which is the divergence the stated domain exists to
     prevent. *)
  if not (V.is_null def.shape) then Config.checkshape def.shape;

  if List.mem_assoc def.dname c.defs then
    c.defs <-
      List.map (fun (k, d) -> if k = def.dname then (k, def) else (k, d)) c.defs
  else c.defs <- c.defs @ [ (def.dname, def) ]

let get c name = List.assoc_opt name c.defs
let has c name = List.mem_assoc name c.defs
let names c = V.oflist (List.map V.vstr (List.sort compare (List.map fst c.defs)))

(* The callback for a phase, by the name the log and the corpus use. *)
let callback d at =
  match at with
  | "define" -> d.define
  | "activate" -> d.activate
  | "deactivate" -> d.deactivate
  | "close" -> d.close
  | _ -> None
