// transform_request utility (mirrors utility/transform_request.rs).

#include "sdk.h"

#include <string.h>

/* `$action` selects the point (see make_point_util); it is never an API
   field, so the body is a copy without it. The caller's map is left
   untouched. */
static voxgig_value* strip_action(voxgig_value* reqdata) {
  if (!voxgig_is_map(reqdata)) return reqdata;
  voxgig_map* rm = voxgig_as_map(reqdata);
  bool has = false;
  for (size_t i = 0; i < rm->len; i++) {
    if (strcmp(rm->entries[i].key, "$action") == 0) { has = true; break; }
  }
  if (!has) return reqdata;
  voxgig_value* body = voxgig_new_map();
  for (size_t i = 0; i < rm->len; i++) {
    if (strcmp(rm->entries[i].key, "$action") != 0) {
      setp(body, rm->entries[i].key, v_share(rm->entries[i].value));
    }
  }
  return body;
}

voxgig_value* transform_request_util(Context* ctx) {
  Spec* spec = ctx->spec;
  voxgig_value* point = ctx->point;

  if (spec) spec_set_step(spec, "reqform");

  voxgig_value* transform = to_map(getp(point, "transform"));
  if (v_is_noval(transform)) return strip_action(ctx->reqdata);

  voxgig_value* reqform = getp(transform, "req");
  if (v_is_noval(reqform) || v_is_null(reqform)) return strip_action(ctx->reqdata);

  voxgig_value* store = cmap(1, "reqdata", v_share(ctx->reqdata));
  /* Return the transform result verbatim, as the ts reference does. Falling
     back to ctx->reqdata meant a reqform naming a path that does not resolve
     sent the WHOLE request data instead of nothing. */
  return strip_action(voxgig_transform(store, reqform, NULL));
}
