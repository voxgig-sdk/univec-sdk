(* Univec SDK core types.
 *
 * The SDK data model is the vendored voxgig struct `value` type
 * (utility/voxgig_struct.ml): a JSON-shaped, reference-stable node used for
 * ctx data, specs, options, transport payloads and results — exactly as the
 * Python/Go SDKs pass map[string]any around.
 *
 * OCaml is functional, but the operation pipeline is inherently a
 * shared-mutable state machine (feature hooks observe and mutate the context
 * across stages, transport wrappers re-bind the fetcher). So the pipeline
 * objects — context, control, spec, response, result, operation, the utility
 * bundle, features and entities — are modelled as mutable records, and the
 * feature/utility indirection that the dynamic donors get from late binding
 * is reproduced here with closure-valued record fields (the `utility`
 * registrar pattern). Everything is defined in one mutually-recursive block
 * so context <-> utility <-> feature <-> entity can reference each other. *)

open Voxgig_struct

(* Branded SDK error. Raised as `Sdk_error_exc` on the throwing path; carried
 * as `sdk_error option` on the (value, err) pipeline return tuples. *)
type sdk_error = {
  mutable err_code : string;
  mutable err_msg : string;
  mutable err_result : value;
  mutable err_spec : value;
}

exception Sdk_error_exc of sdk_error

(* A pipeline stage stashes its product (or a feature-supplied short-circuit
 * error) on ctx.out under the stage name (mirrors the py ctx.out dict). *)
type out_entry =
  | OErr of sdk_error
  | OPoint of value
  | OSpec of spec
  | OResponse of response
  | OResult of result

(* Per-call control state (throw policy, error, explain trace, actor, paging). *)
and control = {
  mutable ctrl_throw : bool option;
  mutable ctrl_err : sdk_error option;
  mutable ctrl_explain : value;   (* Map when explain is on, else Noval *)
  mutable ctrl_actor : value;     (* Str or Noval *)
  mutable ctrl_paging : value;    (* Map or Noval *)
}

and operation = {
  mutable op_entity : string;
  mutable op_name : string;
  mutable op_input : string;
  mutable op_points : value;      (* List *)
  mutable op_alias : value;       (* Map or Noval *)
}

and spec = {
  mutable sp_parts : value;
  mutable sp_headers : value;     (* Map *)
  mutable sp_alias : value;       (* Map *)
  mutable sp_base : string;
  mutable sp_prefix : string;
  mutable sp_suffix : string;
  mutable sp_params : value;      (* Map *)
  mutable sp_query : value;       (* Map *)
  mutable sp_step : string;
  mutable sp_method : string;
  mutable sp_body : value;
  mutable sp_url : string;
  mutable sp_path : string;
}

and response = {
  mutable rs_status : int;
  mutable rs_status_text : string;
  mutable rs_headers : value;
  mutable rs_json : value;        (* Func thunk or Noval *)
  mutable rs_body : value;
  mutable rs_err : sdk_error option;
}

and result = {
  mutable rt_ok : bool;
  mutable rt_status : int;
  mutable rt_status_text : string;
  mutable rt_headers : value;     (* Map *)
  mutable rt_body : value;
  mutable rt_err : sdk_error option;
  mutable rt_resdata : value;
  mutable rt_resmatch : value;    (* Map or Noval *)
  mutable rt_paging : value;      (* paging feature *)
  mutable rt_streaming : bool;    (* streaming feature *)
  mutable rt_stream : (unit -> value list) option;
}

(* A lean view of the vendored struct, exposed on utility.struct as required
 * so consumers reach the same data utilities the pipeline is built on. *)
and struct_api = {
  s_getprop : value -> value -> value;
  s_setprop : value -> value -> value -> value;
  s_getpath : value -> value -> value;
  s_setpath : value -> value -> value -> value;
  s_getelem : value -> value -> value;
  s_haskey : value -> value -> bool;
  s_clone : value -> value;
  s_merge : value list -> value;
  s_items : value -> value;
  s_keysof : value -> string list;
  s_size : value -> int;
  s_isempty : value -> bool;
  s_isnode : value -> bool;
  s_ismap : value -> bool;
  s_islist : value -> bool;
  s_stringify : value -> string;
  s_jsonify : value -> string;
  s_escurl : value -> string;
  s_escre : value -> string;
  s_transform : value -> value -> value;
  s_validate : value -> value -> value;
  s_select : value -> value -> value;
}

(* The utility bundle. `fetcher` (transport) and `custom` (caller utilities)
 * vary per client; the rest are wired once by Sdk_runtime.register. Every
 * function is a closure-valued field so utilities/features can reference each
 * other through the record without an OCaml module cycle. The (value, err)
 * tuple return mirrors the py utilities. *)
and utility = {
  mutable u_custom : value;       (* Map of custom callables *)
  mutable u_struct : struct_api;
  mutable u_fetcher : ctx -> string -> value -> (value * sdk_error option);
  mutable u_clean : ctx -> value -> value;
  mutable u_done : ctx -> value;
  mutable u_make_error : ctx -> sdk_error option -> value;
  mutable u_feature_add : ctx -> feature -> unit;
  mutable u_feature_hook : ctx -> string -> unit;
  mutable u_feature_init : ctx -> feature -> unit;
  mutable u_make_fetch_def : ctx -> (value * sdk_error option);
  mutable u_make_context : ctxspec -> ctx option -> ctx;
  mutable u_make_options : ctx -> value;
  mutable u_make_request : ctx -> (response option * sdk_error option);
  mutable u_make_response : ctx -> (response option * sdk_error option);
  mutable u_make_result : ctx -> (result option * sdk_error option);
  mutable u_make_point : ctx -> (value * sdk_error option);
  mutable u_make_spec : ctx -> (spec option * sdk_error option);
  mutable u_make_url : ctx -> (string * sdk_error option);
  mutable u_param : ctx -> value -> value;
  mutable u_prepare_auth : ctx -> (spec option * sdk_error option);
  mutable u_prepare_body : ctx -> value;
  mutable u_prepare_headers : ctx -> value;
  mutable u_prepare_method : ctx -> string;
  mutable u_prepare_params : ctx -> value;
  mutable u_prepare_path : ctx -> string;
  mutable u_prepare_query : ctx -> value;
  mutable u_graphql_body : ctx -> value;
  mutable u_graphql_errors : ctx -> bool;
  mutable u_result_basic : ctx -> unit;
  mutable u_result_body : ctx -> unit;
  mutable u_result_headers : ctx -> unit;
  mutable u_transform_request : ctx -> value;
  mutable u_transform_response : ctx -> value;
}

(* A pipeline feature: name/version/active bookkeeping, the `f_options`
 * ordering carrier consulted by feature_add (__before__/__after__/__replace__),
 * an `init` and a name-keyed hook dispatch (the dynamic getattr(f,name) of the
 * py port, expressed as a closure that pattern-matches the hook name). *)
and feature = {
  mutable f_name : string;
  mutable f_version : string;
  mutable f_active : bool;
  mutable f_options : value;      (* ordering carrier; Map or Noval *)
  mutable f_init : ctx -> value -> unit;
  mutable f_hook : string -> ctx -> unit;
}

and sdk_client = {
  mutable cl_mode : string;
  mutable cl_features : feature list;
  mutable cl_options : value;
  mutable cl_utility : utility;
  mutable cl_rootctx : ctx option;
  (* Feature tracking sink (py's dynamic client._retry / _cache / ...): a
   * struct Map keyed by feature name. Reference-stable so a feature can grab
   * its bucket once and keep mutating it. *)
  mutable cl_track : value;
}

and entity_obj = {
  mutable e_name : string;
  mutable e_client : sdk_client;
  mutable e_utility : utility;
  mutable e_entopts : value;
  mutable e_data : value;
  mutable e_match : value;
  mutable e_entctx : ctx;
  mutable e_make : unit -> entity_obj;
  mutable e_data_set : value -> unit;
  mutable e_data_get : unit -> value;
  mutable e_match_set : value -> unit;
  mutable e_match_get : unit -> value;
  (* Every operation resolves to the ENTITY, not the raw record - e_list to
   * one per record. The record is reached through e_data_get. `value` is a
   * closed data union with no slot for an entity, so the CONTRACT lives in
   * these signatures. See AGENTS.md "Entity operations return ENTITIES". *)
  mutable e_load : value -> value -> entity_obj;
  mutable e_list : value -> value -> entity_obj list;
  mutable e_create : value -> value -> entity_obj;
  mutable e_update : value -> value -> entity_obj;
  mutable e_remove : value -> value -> entity_obj;
  (* e_remove resolves to the entity, marked. The instance KEEPS the data it
   * held - a caller can still read what was deleted - but it is no longer a
   * live record. *)
  mutable e_deleted : bool;
  mutable e_mark_deleted : unit -> unit;
  (* stream action args callopts -> a lazy Seq over result items. *)
  mutable e_stream : string -> value -> value -> value Seq.t;
}

(* Construction spec for a context (py passes an untyped ctxmap dict that
 * mixes struct data with live objects; OCaml uses this typed optional-field
 * builder, mirroring the rust CtxSpec). *)
and ctxspec = {
  mutable cs_opname : string option;
  mutable cs_client : sdk_client option;
  mutable cs_utility : utility option;
  mutable cs_ctrl : value option;       (* ctrl as a {throw,explain,actor,paging} map *)
  mutable cs_meta : value option;
  mutable cs_config : value option;
  mutable cs_entopts : value option;
  mutable cs_options : value option;
  mutable cs_entity : entity_obj option;
  mutable cs_shared : value option;
  mutable cs_opmap : (string, operation) Hashtbl.t option;
  mutable cs_data : value option;
  mutable cs_reqdata : value option;
  mutable cs_match : value option;
  mutable cs_reqmatch : value option;
  mutable cs_point : value option;
  mutable cs_spec : spec option;
  mutable cs_result : result option;
  mutable cs_response : response option;
}

and ctx = {
  mutable c_id : string;
  mutable c_out : (string, out_entry) Hashtbl.t;
  mutable c_ctrl : control;
  mutable c_meta : value;
  mutable c_client : sdk_client option;
  mutable c_utility : utility option;
  mutable c_op : operation;
  mutable c_point : value;        (* Map or Noval *)
  mutable c_config : value;
  mutable c_entopts : value;
  mutable c_options : value;
  mutable c_opmap : (string, operation) Hashtbl.t;
  mutable c_response : response option;
  mutable c_result : result option;
  mutable c_spec : spec option;
  mutable c_data : value;
  mutable c_reqdata : value;
  mutable c_match : value;
  mutable c_reqmatch : value;
  mutable c_entity : entity_obj option;
  mutable c_shared : value;
  (* per-op feature scratch (telemetry span, metrics start, debug entry,
   * audit-seen flag): keyed by feature, holding a struct value. *)
  mutable c_scratch : (string, value) Hashtbl.t;
}
