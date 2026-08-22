// make_request utility (mirrors utility/make_request.rs).

#include "sdk.h"

Response* make_request_util(Context* ctx, PNError** err) {
  *err = NULL;

  if (ctx->out_request) {
    return ctx->out_request;
  }

  Response* response = response_new(voxgig_new_map());
  SdkResult* result = result_new(voxgig_new_map());
  ctx->result = result;

  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "request_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }

  PNError* fderr = NULL;
  voxgig_value* fetchdef = make_fetch_def_util(ctx, &fderr);
  if (fderr) {
    response->err = fderr;
    ctx->response = response;
    spec_set_step(spec, "postrequest");
    return response;  // note: not an *err — pipeline continues
  }

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "fetchdef", v_share(fetchdef));
  }

  spec_set_step(spec, "prerequest");

  const char* url = get_str(fetchdef, "url");
  url = url ? url : "";
  PNError* ferr = NULL;
  voxgig_value* fetched = utility_fetch(ctx->utility, ctx, url, fetchdef, &ferr);

  Response* out_response;
  if (ferr) {
    response->err = ferr;
    out_response = response;
  } else if (voxgig_is_map(fetched)) {
    out_response = response_new(fetched);
  } else if (v_is_noval(fetched) || v_is_null(fetched)) {
    Response* r = response_new(voxgig_new_map());
    r->err = context_make_error(ctx, "request_no_response", "response: undefined");
    out_response = r;
  } else {
    response->err = context_make_error(ctx, "request_invalid_response", "response: invalid type");
    out_response = response;
  }

  spec_set_step(spec, "postrequest");
  ctx->response = out_response;

  return out_response;
}
