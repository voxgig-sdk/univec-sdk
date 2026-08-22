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
  voxgig_value* out = voxgig_transform(store, reqform, NULL);
  if (out && !v_is_noval(out)) return out;
  return ctx->reqdata;
}
