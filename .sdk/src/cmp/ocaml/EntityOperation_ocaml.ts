
import { ocamlString } from './utility_ocaml'


// Emit the OCaml source for one entity CRUD operation, as an assignment to
// the entity_obj's op field (e_load / e_list / ...). Present ops run the real
// pipeline via run_op with an op-specific post_done writeback; absent ops
// install a stub that errors at call time (so the entity_obj record is always
// fully populated). Mirrors the rust/py Entity op fragments.
function entityOp(opname: string, present: boolean, entityname: string): string {
  const field =
    'load' === opname ? 'e_load' :
      'list' === opname ? 'e_list' :
        'create' === opname ? 'e_create' :
          'update' === opname ? 'e_update' : 'e_remove'

  if (!present) {
    return `  ent.${field} <- (fun _ _ ->
      raise (Sdk_error_exc (mk_error "unsupported_op"
        "Operation \\"${ocamlString(opname)}\\" not supported by entity \\"${ocamlString(entityname)}\\".")));
`
  }

  const inputField = ('create' === opname || 'update' === opname) ? 'cs_reqdata' : 'cs_reqmatch'
  const arg = ('create' === opname || 'update' === opname) ? 'reqdata' : 'reqmatch'

  // Writeback after a successful op (mirrors the py op fragments):
  //   load/update/remove -> match + data ; list -> match ; create -> data
  const writeMatch = ('list' === opname || 'load' === opname || 'update' === opname || 'remove' === opname)
  const writeData = ('create' === opname || 'load' === opname || 'update' === opname || 'remove' === opname)

  let post = ''
  if (writeMatch) {
    post += `            (match result.rt_resmatch with Map _ as m -> ent.e_match <- m | _ -> ());\n`
  }
  if (writeData) {
    post += `            if not (is_nullish result.rt_resdata) then
              ent.e_data <- (match to_map (clone result.rt_resdata) with Map _ as m -> m | _ -> empty_map ());\n`
  }
  if ('' === post) {
    post = `            ()\n`
  }

  // The op resolves to the ENTITY (see Sdk_types). `list` builds one entity
  // per record here, since make_result works in `value` and cannot; `remove`
  // marks the instance. With throwing disabled run_op returns the error
  // payload, which an entity_obj return cannot carry, so that path resolves to
  // the entity too and the caller reads ctrl.err - the mechanism no-throw mode
  // documents anyway.
  const tail =
    'list' === opname
      ? `      let out = run_op ctx post_done in
      (match out with
       | List items ->
         List.map (fun entry ->
             let e = ent.e_make () in
             (match entry with Map _ -> e.e_data_set entry | _ -> ());
             e)
           !items
       | _ -> []));
`
      : 'remove' === opname
        ? `      ignore (run_op ctx post_done);
      ent.e_mark_deleted ();
      ent);
`
        : `      ignore (run_op ctx post_done);
      ent);
`

  return `  ent.${field} <- (fun ${arg} ctrl ->
      let ${arg} = if is_nullish ${arg} then empty_map () else ${arg} in
      let ctx = utility.u_make_context
          { (default_ctxspec ()) with
            cs_opname = Some "${ocamlString(opname)}";
            cs_ctrl = (match ctrl with Noval | Null -> None | c -> Some c);
            cs_match = Some ent.e_match; cs_data = Some ent.e_data;
            ${inputField} = Some ${arg} }
          (Some entctx) in
      let post_done () =
          match ctx.c_result with
          | Some result ->
${post}          | None -> () in
${tail}`
}


export {
  entityOp,
}
