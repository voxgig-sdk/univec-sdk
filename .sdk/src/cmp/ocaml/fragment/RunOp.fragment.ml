(* Run the operation pipeline, firing feature hooks between stages via the
 * generated hook-marker lines. post_done runs after the PreDone stage, just
 * before done. Errors from any stage go through make_error (which either
 * returns resdata when throw is disabled, or raises). *)
let run_op (ctx : ctx) (post_done : unit -> unit) : value =
  let utility = cu ctx in
  let bail (err : sdk_error option) = raise (Op_return (utility.u_make_error ctx err)) in
  try
    (try
       (* #PrePoint-Hook *)
       let point = (match utility.u_make_point ctx with (p, None) -> p | (_, e) -> bail e) in
       Hashtbl.replace ctx.c_out "point" (OPoint point);
       (* #PreSpec-Hook *)
       let spec = (match utility.u_make_spec ctx with (Some s, None) -> s | (_, e) -> bail e) in
       Hashtbl.replace ctx.c_out "spec" (OSpec spec);
       (* #PreRequest-Hook *)
       let resp = (match utility.u_make_request ctx with (Some r, None) -> r | (_, e) -> bail e) in
       Hashtbl.replace ctx.c_out "request" (OResponse resp);
       (* #PreResponse-Hook *)
       let resp2 = (match utility.u_make_response ctx with (Some r, None) -> r | (_, e) -> bail e) in
       Hashtbl.replace ctx.c_out "response" (OResponse resp2);
       (* #PreResult-Hook *)
       let result = (match utility.u_make_result ctx with (Some r, None) -> r | (_, e) -> bail e) in
       Hashtbl.replace ctx.c_out "result" (OResult result);
       (* #PreDone-Hook *)
       post_done ();
       utility.u_done ctx
     with Op_return v -> v)
  with
  | Sdk_error_exc _ as e ->
    (* #PreUnexpected-Hook *)
    raise e
