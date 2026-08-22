// done utility (mirrors utility/done.rs).

#include "sdk.h"

voxgig_value* done_util(Context* ctx, PNError** err) {
  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    voxgig_value* explain = clean_util(ctx, c->explain);
    voxgig_value* res = getp(explain, "result");
    if (voxgig_is_map(res)) {
      voxgig_value* rm = to_map(res);
      voxgig_value* k = voxgig_new_string("err");
      voxgig_delprop(rm, k);
      voxgig_release(k);
    }
    c->explain = explain;
  }

  SdkResult* result = ctx->result;
  if (result && result->ok) {
    if (err) *err = NULL;
    return v_share(result->resdata);
  }

  return make_error_util(ctx, NULL, err);
}
