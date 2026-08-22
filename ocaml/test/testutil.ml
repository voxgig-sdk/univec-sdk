(* Minimal test harness (no third-party deps): each test case is registered
 * and run at module-init time via `test`, recording pass/fail; a final
 * summary module prints counts and exits non-zero on any failure. *)

open Voxgig_struct
open Sdk_types

let npass = ref 0
let nfail = ref 0
let failures : string list ref = ref []

let fail_msg (e : exn) : string =
  match e with
  | Sdk_error_exc er -> er.err_msg
  | Failure m -> m
  | e -> Printexc.to_string e

let test (name : string) (f : unit -> unit) : unit =
  try f (); incr npass
  with e -> incr nfail; failures := (name ^ " :: " ^ fail_msg e) :: !failures

let check (name : string) (cond : bool) : unit =
  if not cond then failwith name

let check_int (name : string) (got : int) (expected : int) : unit =
  if got <> expected then failwith (Printf.sprintf "%s: expected %d, got %d" name expected got)

let check_str (name : string) (got : string) (expected : string) : unit =
  if got <> expected then failwith (Printf.sprintf "%s: expected %S, got %S" name expected got)

(* value equality that tolerates Func (physical) instead of raising *)
let rec veq (a : value) (b : value) : bool =
  match a, b with
  | Noval, Noval | Null, Null -> true
  | Bool x, Bool y -> x = y
  | Num x, Num y -> x = y
  | Str x, Str y -> x = y
  | List x, List y -> List.length !x = List.length !y && List.for_all2 veq !x !y
  | Map x, Map y ->
    List.length x.entries = List.length y.entries
    && List.for_all (fun (k, v) -> match omap_get y k with Some w -> veq v w | None -> false) x.entries
  | Func _, Func _ -> a == b
  | _ -> false

let check_vnum (name : string) (v : value) (n : float) : unit =
  match v with Num x when x = n -> () | _ -> failwith (name ^ ": expected Num " ^ string_of_float n ^ ", got " ^ stringify v)

let check_vstr (name : string) (v : value) (s : string) : unit =
  match v with Str x when x = s -> () | _ -> failwith (name ^ ": expected Str " ^ s ^ ", got " ^ stringify v)

let check_vbool (name : string) (v : value) (b : bool) : unit =
  match v with Bool x when x = b -> () | _ -> failwith (name ^ ": expected Bool " ^ string_of_bool b ^ ", got " ^ stringify v)

let summary () : unit =
  List.iter (fun m -> print_endline ("FAIL " ^ m)) (List.rev !failures);
  Printf.printf "\nSDK PASS %d  FAIL %d\n" !npass !nfail;
  if !nfail > 0 then exit 1
