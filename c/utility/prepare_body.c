// prepare_body utility (mirrors utility/prepare_body.rs).

#include "sdk.h"

#include <string.h>

voxgig_value* prepare_body_util(Context* ctx) {
  if (strcmp(ctx->op->input, "data") == 0) {
    return transform_request_util(ctx);
  }
  return voxgig_new_undef();
}
