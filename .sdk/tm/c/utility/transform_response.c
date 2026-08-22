// transform_response utility (mirrors utility/transform_response.rs).

#include "sdk.h"

voxgig_value* transform_response_util(Context* ctx) {
  Spec* spec = ctx->spec;
  SdkResult* result = ctx->result;
  voxgig_value* point = ctx->point;

  if (spec) spec_set_step(spec, "resform");

  if (!result) return voxgig_new_undef();
  if (!result->ok) return voxgig_new_undef();

  voxgig_value* transform = to_map(getp(point, "transform"));
  if (v_is_noval(transform)) return voxgig_new_undef();

  voxgig_value* resform = getp(transform, "res");
  if (v_is_noval(resform) || v_is_null(resform)) return voxgig_new_undef();

  voxgig_value* store = cmap(7,
      "ok", v_bool(result->ok),
      "status", v_num((double)result->status),
      "statusText", v_str(result->status_text),
      "headers", v_share(result->headers),
      "body", v_share(result->body),
      "resdata", v_share(result->resdata),
      "resmatch", v_share(result->resmatch));

  voxgig_value* out = voxgig_transform(store, resform, NULL);
  if (out && !v_is_noval(out)) {
    result->resdata = out;
    return out;
  }
  return voxgig_new_undef();
}
