// result_headers utility (mirrors utility/result_headers.rs).

#include "sdk.h"

SdkResult* result_headers_util(Context* ctx) {
  Response* response = ctx->response;
  SdkResult* result = ctx->result;

  if (result) {
    voxgig_value* headers = voxgig_new_map();
    if (response && voxgig_is_map(response->headers)) {
      headers = response->headers;
    }
    result->headers = headers;
  }
  return result;
}
