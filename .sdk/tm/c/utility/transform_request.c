// transform_request utility (mirrors utility/transform_request.rs).

#include "sdk.h"

voxgig_value* transform_request_util(Context* ctx) {
  Spec* spec = ctx->spec;
  voxgig_value* point = ctx->point;

  if (spec) spec_set_step(spec, "reqform");

  voxgig_value* transform = to_map(getp(point, "transform"));
  if (v_is_noval(transform)) return ctx->reqdata;

  voxgig_value* reqform = getp(transform, "req");
  if (v_is_noval(reqform) || v_is_null(reqform)) return ctx->reqdata;

  voxgig_value* store = cmap(1, "reqdata", v_share(ctx->reqdata));
  /* Return the transform result verbatim, as the ts reference does. Falling
     back to ctx->reqdata meant a reqform naming a path that does not resolve
     sent the WHOLE request data instead of nothing. */
  return voxgig_transform(store, reqform, NULL);
}
