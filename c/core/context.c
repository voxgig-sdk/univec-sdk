// Operation context (mirrors core/context.rs). Plain heap struct; single
// threaded, never-free — fields mutated in place.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static char* dup_str(const char* s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char* d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

PNError* context_make_error(Context* ctx, const char* code, const char* msg) {
  (void)ctx;
  return pn_error_new(code, msg);
}

Utility* context_util(Context* ctx) { return ctx->utility; }

void ctx_out_set_point_val(Context* ctx, voxgig_value* v) {
  ctx->out_point_kind = OUT_VAL;
  ctx->out_point_val = v;
  ctx->out_point_err = NULL;
}
void ctx_out_set_point_err(Context* ctx, PNError* e) {
  ctx->out_point_kind = OUT_ERR;
  ctx->out_point_err = e;
  ctx->out_point_val = NULL;
}
voxgig_value* ctx_out_extra_get(Context* ctx, const char* key) {
  return getp(ctx->out_extra, key);
}
void ctx_out_extra_set(Context* ctx, const char* key, voxgig_value* v) {
  setp(ctx->out_extra, key, v);
}

static Operation* resolve_op(Context* ctx, const char* opname) {
  const char* entname = ctx->entity ? ctx->entity->vt->get_name(ctx->entity) : "";

  if (opname == NULL || opname[0] == '\0') {
    return operation_new(voxgig_new_map());
  }

  voxgig_value* opcfg;
  {
    const char* keys[5] = {"entity", entname, "op", opname, NULL};
    opcfg = getpath_c(ctx->config, keys);
  }

  const char* input =
      (strcmp(opname, "update") == 0 || strcmp(opname, "create") == 0) ? "data" : "match";

  voxgig_value* targets = getp(opcfg, "points");
  if (!voxgig_is_list(targets)) targets = voxgig_new_list();

  voxgig_value* opmap = cmap(4, "entity", v_str(entname), "name", v_str(opname),
                            "input", v_str(input), "points", targets);
  return operation_new(opmap);
}

Context* context_new(CtxSpec cs, Context* basectx) {
  Context* ctx = (Context*)calloc(1, sizeof(Context));

  char idbuf[32];
  snprintf(idbuf, sizeof(idbuf), "C%lld", (long long)(rand_int(90000000) + 10000000));
  ctx->id = dup_str(idbuf);

  ctx->out_point_kind = OUT_NONE;
  ctx->out_extra = voxgig_new_map();

  // Client.
  ctx->client = cs.client ? cs.client : (basectx ? basectx->client : NULL);
  // Utility.
  ctx->utility = cs.utility ? cs.utility : (basectx ? basectx->utility : NULL);

  // Ctrl.
  if (cs.ctrl) {
    Control* c = control_new();
    bool t;
    if (get_bool(cs.ctrl, "throw", &t)) { c->has_throw = true; c->throw_v = t; }
    voxgig_value* explain = getp(cs.ctrl, "explain");
    if (voxgig_is_map(explain)) c->explain = explain;
    const char* actor = get_str(cs.ctrl, "actor");
    if (actor) { free(c->actor); c->actor = dup_str(actor); }
    voxgig_value* paging = getp(cs.ctrl, "paging");
    if (voxgig_is_map(paging)) c->paging = paging;
    ctx->ctrl = c;
  } else if (cs.ctrl_obj) {
    ctx->ctrl = cs.ctrl_obj;
  } else if (basectx) {
    ctx->ctrl = basectx->ctrl;
  } else {
    ctx->ctrl = control_new();
  }

  // Meta.
  if (cs.meta) {
    ctx->meta = cs.meta;
  } else if (basectx && voxgig_is_map(basectx->meta)) {
    ctx->meta = basectx->meta;
  } else {
    ctx->meta = voxgig_new_map();
  }

  // Config / entopts / options / entity / shared: fall back to base.
  ctx->config = cs.config ? cs.config : (basectx ? basectx->config : voxgig_new_undef());
  ctx->entopts = cs.entopts ? cs.entopts : (basectx ? basectx->entopts : voxgig_new_undef());
  ctx->options = cs.options ? cs.options : (basectx ? basectx->options : voxgig_new_undef());
  ctx->entity = cs.entity ? cs.entity : (basectx ? basectx->entity : NULL);
  if (cs.shared) {
    ctx->shared = cs.shared;
  } else if (basectx && voxgig_is_map(basectx->shared)) {
    ctx->shared = basectx->shared;
  } else {
    ctx->shared = voxgig_new_undef();
  }

  // Data maps (never inherited).
  ctx->data = (cs.data && voxgig_is_map(cs.data)) ? cs.data : voxgig_new_map();
  ctx->reqdata = (cs.reqdata && voxgig_is_map(cs.reqdata)) ? cs.reqdata : voxgig_new_map();
  ctx->mtch = (cs.mtch && voxgig_is_map(cs.mtch)) ? cs.mtch : voxgig_new_map();
  ctx->reqmatch = (cs.reqmatch && voxgig_is_map(cs.reqmatch)) ? cs.reqmatch : voxgig_new_map();

  // Point / spec / result / response: fall back to base.
  if (cs.point) {
    ctx->point = cs.point;
  } else if (basectx && voxgig_is_map(basectx->point)) {
    ctx->point = basectx->point;
  } else {
    ctx->point = voxgig_new_undef();
  }
  ctx->spec = cs.spec ? cs.spec : (basectx ? basectx->spec : NULL);
  ctx->result = cs.result ? cs.result : (basectx ? basectx->result : NULL);
  ctx->response = cs.response ? cs.response : (basectx ? basectx->response : NULL);

  // Resolve operation.
  ctx->op = resolve_op(ctx, cs.opname);

  return ctx;
}
