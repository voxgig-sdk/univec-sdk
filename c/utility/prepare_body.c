// prepare_body utility (mirrors utility/prepare_body.rs).

#include "sdk.h"

#include <string.h>

voxgig_value* prepare_body_util(Context* ctx) {
  if (strcmp(ctx->op->input, "data") == 0) {
    if (media_is_raw_request(ctx->point)) return media_raw_body(ctx->reqdata);
    return transform_request_util(ctx);
  }
  return voxgig_new_undef();
}
