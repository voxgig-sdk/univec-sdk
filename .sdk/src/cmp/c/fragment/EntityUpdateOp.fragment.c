// EJECT-START

static void entyvar_update_postdone(entyvar_entity* self, Context* ctx) {
  SdkResult* result = ctx->result;
  if (result) {
    voxgig_value* resmatch = result->resmatch;
    voxgig_value* resdata = result->resdata;
    if (voxgig_is_map(resmatch)) self->mtch = resmatch;
    if (!v_is_noval(resdata) && !v_is_null(resdata)) {
      voxgig_value* m = to_map(voxgig_clone(resdata));
      self->data = voxgig_is_map(m) ? m : voxgig_new_map();
    }
  }
}

static Entity* entyvar_update(Entity* e, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err) {
  entyvar_entity* self = (entyvar_entity*)e;
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  cs.opname = "update";
  cs.ctrl = ctrl;
  cs.mtch = self->mtch;
  cs.data = self->data;
  cs.reqdata = reqdata;
  Context* ctx = make_context_util(cs, entyvar_ent_ctx(self));
  entyvar_run_op(self, ctx, entyvar_update_postdone, err);
  if (*err) return NULL;

  // The operation resolves to THIS entity: run_op has just absorbed the
  // result into it, and the caller reaches the record through vt->data.
  // See AGENTS.md "Entity operations return ENTITIES".

  return e;
}

// EJECT-END
