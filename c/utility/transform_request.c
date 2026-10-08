// transform_request utility (mirrors utility/transform_request.rs).

#include "sdk.h"

#include <string.h>

static const char* ROUTED_KINDS[] = { "header", "cookie", "query" };

static bool field_arg(Context* ctx, const char* name) {
  bool found = false;
  for (size_t k = 0; k < 3 && !found; k++) {
    voxgig_value* defs = getpath2(ctx->point, "args", ROUTED_KINDS[k]);
    if (voxgig_is_list(defs)) {
      voxgig_list* dl = voxgig_as_list(defs);
      for (size_t i = 0; i < dl->len && !found; i++) {
        voxgig_value* n = getp(dl->items[i], "name");
        voxgig_value* f = getp(dl->items[i], "field");
        found = v_str_eq(n, name) && voxgig_is_bool(f) && voxgig_as_bool(f);
        voxgig_release(n);
        voxgig_release(f);
      }
    }
    voxgig_release(defs);
  }
  return found;
}

/* A header, cookie or query argument travels where prepare_headers_util or
   prepare_query_util sends it, so the body is built from the request data
   without it, unless the point marks it as a field the body keeps. */
static voxgig_value* routed_args(Context* ctx) {
  voxgig_value* routed = voxgig_new_list();
  for (size_t k = 0; k < 3; k++) {
    voxgig_value* more = call_args(ctx, ROUTED_KINDS[k]);
    voxgig_list* ml = voxgig_as_list(more);
    for (size_t i = 0; i < ml->len; i++) {
      voxgig_list* arg = voxgig_as_list(ml->items[i]);
      if (field_arg(ctx, voxgig_as_string(arg->items[0]))) continue;
      voxgig_list_push(voxgig_as_list(routed), v_share(ml->items[i]));
    }
    voxgig_release(more);
  }
  return routed;
}

static bool routed_arg(voxgig_value* routed, const char* key) {
  voxgig_list* rl = voxgig_as_list(routed);
  for (size_t i = 0; i < rl->len; i++) {
    voxgig_list* arg = voxgig_as_list(rl->items[i]);
    if (strcmp(voxgig_as_string(arg->items[0]), key) == 0) return true;
  }
  return false;
}

/* `$action` selects the point (see make_point_util); it is never an API
   field, so the body is a copy without it, or, given the routed arguments,
   without those. The caller's map is left untouched. */
static bool dropped(const char* key, voxgig_value* routed) {
  return NULL == routed ? strcmp(key, "$action") == 0 : routed_arg(routed, key);
}

static voxgig_value* omit_keys(voxgig_value* reqdata, voxgig_value* routed) {
  if (!voxgig_is_map(reqdata)) return reqdata;
  voxgig_map* rm = voxgig_as_map(reqdata);
  bool has = false;
  for (size_t i = 0; i < rm->len; i++) {
    if (dropped(rm->entries[i].key, routed)) { has = true; break; }
  }
  if (!has) return reqdata;
  voxgig_value* body = voxgig_new_map();
  for (size_t i = 0; i < rm->len; i++) {
    if (!dropped(rm->entries[i].key, routed)) {
      setp(body, rm->entries[i].key, v_share(rm->entries[i].value));
    }
  }
  return body;
}

static voxgig_value* strip_action(voxgig_value* reqdata) {
  return omit_keys(reqdata, NULL);
}

voxgig_value* transform_request_util(Context* ctx) {
  Spec* spec = ctx->spec;
  voxgig_value* point = ctx->point;

  if (spec) spec_set_step(spec, "reqform");

  voxgig_value* routed = NULL == point ? NULL : routed_args(ctx);
  voxgig_value* data = NULL == routed ? ctx->reqdata : omit_keys(ctx->reqdata, routed);
  if (NULL != routed) voxgig_release(routed);

  voxgig_value* transform = to_map(getp(point, "transform"));
  if (v_is_noval(transform)) return strip_action(data);

  voxgig_value* reqform = getp(transform, "req");
  if (v_is_noval(reqform) || v_is_null(reqform)) return strip_action(data);

  voxgig_value* store = cmap(1, "reqdata", v_share(data));
  /* Return the transform result verbatim, as the ts reference does. Falling
     back to ctx->reqdata meant a reqform naming a path that does not resolve
     sent the WHOLE request data instead of nothing. */
  return strip_action(voxgig_transform(store, reqform, NULL));
}
