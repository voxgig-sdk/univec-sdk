(* Univec SDK value helpers — thin wrappers over the vendored voxgig
 * struct `value` type used throughout the pipeline. *)

open Voxgig_struct
open Sdk_types

(* ----- map/list construction & access ----- *)

let getp (v : value) (key : string) : value = getprop v (Str key)

let setp (v : value) (key : string) (nv : value) : unit =
  ignore (setprop v (Str key) nv)

let jo (pairs : (string * value) list) : value =
  let m = empty_map () in
  List.iter (fun (k, v) -> ignore (setprop m (Str k) v)) pairs;
  m

let ja (items : value list) : value = lst items

let to_map (v : value) : value = match v with Map _ -> v | _ -> Noval

let to_int (v : value) : int = match v with Num n -> int_of_float n | _ -> -1

let get_str (m : value) (key : string) : string option =
  match getp m key with Str s -> Some s | _ -> None

let get_str_d (m : value) (key : string) (d : string) : string =
  match getp m key with Str s -> s | _ -> d

let get_bool (m : value) (key : string) : bool option =
  match getp m key with Bool b -> Some b | _ -> None

let get_num (m : value) (key : string) : float option =
  match getp m key with Num n -> Some n | _ -> None

let is_true (v : value) : bool = match v with Bool true -> true | _ -> false

let vbool b = Bool b
let vnum (n : float) = Num n
let vint_of (i : int) = Num (float_of_int i)

(* ----- dotted-path struct access ----- *)

let getpath_s (store : value) (dotpath : string) : value =
  getpath store (Str dotpath)

(* ----- callables (struct Func) -----
 * All SDK callables (json thunks, injected clocks / key & id generators,
 * exporters/sinks, custom transports, custom utilities) ignore the injector,
 * ref and store arguments and read their argument from `val`. A dummy inj is
 * safe because these closures never touch it (same pattern the struct corpus
 * runner uses). *)
let call_vfn (fn : value) (arg : value) : value =
  match fn with Func f -> f (Obj.magic 0 : inj) arg "" Noval | _ -> Noval

let vfunc0 (f : unit -> value) : value = Func (fun _ _ _ _ -> f ())
let vfunc1 (f : value -> value) : value = Func (fun _ v _ _ -> f v)
let json_thunk (data : value) : value = Func (fun _ _ _ _ -> data)
let call_json (j : value) : value = call_vfn j Noval
let is_callable (v : value) : bool = match v with Func _ -> true | _ -> false

(* ----- errors ----- *)

let mk_error (code : string) (msg : string) : sdk_error =
  { err_code = code; err_msg = msg; err_result = Noval; err_spec = Noval }

let ctx_make_error (_ctx : ctx) (code : string) (msg : string) : sdk_error =
  mk_error code msg

let err_msg_of (e : sdk_error) : string = e.err_msg

(* ----- ctx utility / client unwrap ----- *)

let cu (ctx : ctx) : utility =
  match ctx.c_utility with Some u -> u | None -> failwith "context utility not set"

let cc (ctx : ctx) : sdk_client =
  match ctx.c_client with Some c -> c | None -> failwith "context client not set"

(* ----- per-op feature scratch ----- *)

let scratch_get (ctx : ctx) (key : string) : value option =
  Hashtbl.find_opt ctx.c_scratch key

let scratch_set (ctx : ctx) (key : string) (v : value) : unit =
  Hashtbl.replace ctx.c_scratch key v

let scratch_del (ctx : ctx) (key : string) : unit =
  Hashtbl.remove ctx.c_scratch key

(* ----- client feature-tracking sink (py client._retry / _cache / ...) ----- *)

let track_get (client : sdk_client) (name : string) : value =
  getp client.cl_track name

let track_set (client : sdk_client) (name : string) (v : value) : unit =
  setp client.cl_track name v

(* ----- default clock (no Unix dep) ----- *)

let default_now_ms () : float = Sys.time () *. 1000.0

(* ----- number coercion for option reads ----- *)

let num_opt (v : value) : float option =
  match v with Num n -> Some n | _ -> None

let int_opt (v : value) : int option =
  match v with Num n -> Some (int_of_float n) | _ -> None
