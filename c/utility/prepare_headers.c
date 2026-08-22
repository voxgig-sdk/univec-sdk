// prepare_headers utility (mirrors utility/prepare_headers.rs).

#include "sdk.h"

voxgig_value* prepare_headers_util(Context* ctx) {
  voxgig_value* options = ctx->client ? sdk_options_map(ctx->client) : ctx->options;

  voxgig_value* headers = getp(options, "headers");
  if (v_is_noval(headers) || v_is_null(headers)) return voxgig_new_map();

  voxgig_value* cloned = voxgig_clone(headers);
  return voxgig_is_map(cloned) ? cloned : voxgig_new_map();
}
