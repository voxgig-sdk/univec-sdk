// result_body utility (mirrors utility/result_body.rs).

#include "sdk.h"

SdkResult* result_body_util(Context* ctx) {
  Response* response = ctx->response;
  SdkResult* result = ctx->result;

  if (result && response) {
    voxgig_value* json = response->json;
    voxgig_value* body = response->body;
    if (voxgig_is_func(json) && !v_is_noval(body) && !v_is_null(body)) {
      result->body = call_json(json);
    }
    if (response->unreadable) {
      voxgig_value* sent = ctx->spec ? ctx->spec->headers : NULL;
      result->err = unreadable_body(ctx, result->status, result->headers, body, sent, result->err);
    }
  }
  return result;
}
