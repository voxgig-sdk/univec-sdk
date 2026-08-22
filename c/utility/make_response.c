// make_response utility (mirrors utility/make_response.rs).

#include "sdk.h"

Response* make_response_util(Context* ctx, PNError** err) {
  *err = NULL;

  if (ctx->out_response) {
    return ctx->out_response;
  }

  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "response_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }
  Response* response = ctx->response;
  if (!response) {
    *err = context_make_error(ctx, "response_no_response", "Expected context response property to be defined.");
    return NULL;
  }
  SdkResult* result = ctx->result;
  if (!result) {
    *err = context_make_error(ctx, "response_no_result", "Expected context result property to be defined.");
    return NULL;
  }

  spec_set_step(spec, "response");

  result_basic_util(ctx);
  result_headers_util(ctx);
  result_body_util(ctx);

  // GraphQL reports failures as a top-level `errors` array under HTTP 200,
  // so result_basic's status check never sees them. Lift them here, before
  // the response transform tries to unwrap data that is not there.
  graphql_errors_util(ctx);

  transform_response_util(ctx);

  if (result->err == NULL) {
    result->ok = true;
  }

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "result", result_to_value(result));
  }

  return response;
}
