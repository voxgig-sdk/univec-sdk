// make_spec utility (mirrors utility/make_spec.rs).

#include "sdk.h"

#include <stdio.h>
#include <string.h>

Spec* make_spec_util(Context* ctx, PNError** err) {
  *err = NULL;

  if (ctx->out_spec) {
    ctx->spec = ctx->out_spec;
    return ctx->out_spec;
  }

  voxgig_value* point = ctx->point;
  voxgig_value* options = ctx->options;

  voxgig_value* specmap = voxgig_new_map();
  setp(specmap, "base", getp(options, "base"));
  setp(specmap, "prefix", getp(options, "prefix"));
  setp(specmap, "suffix", getp(options, "suffix"));
  setp(specmap, "parts", getp(point, "parts"));
  setp(specmap, "step", v_str("start"));

  Spec* spec = spec_new(specmap);
  ctx->spec = spec;

  const char* method = prepare_method_util(ctx);
  spec_set_method(spec, method);

  voxgig_value* allow_method_v = getpath2(options, "allow", "method");
  const char* allow_method = voxgig_is_string(allow_method_v) ? voxgig_as_string(allow_method_v) : "";
  if (!strstr(allow_method, method)) {
    char buf[512];
    snprintf(buf, sizeof(buf),
             "Method \"%s\" not allowed by SDK option allow.method value: \"%s\"",
             method, allow_method);
    *err = context_make_error(ctx, "spec_method_allow", buf);
    return NULL;
  }

  spec->params = prepare_params_util(ctx);
  spec->query = prepare_query_util(ctx);
  spec->headers = prepare_headers_util(ctx);

  voxgig_value* pkind = getp(ctx->point, "kind");
  bool is_graphql = voxgig_is_string(pkind) &&
                    strcmp(voxgig_as_string(pkind), "graphql") == 0;

  if (is_graphql) {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepare_body is skipped deliberately
    // — it only emits a body for data-input ops, whereas every GraphQL op
    // posts one, including load/list/remove.
    spec->body = graphql_body_util(ctx);
    spec_set_path(spec, "");
    // prepare_query already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so
    // leaving them would send /graphql?id=i1.
    spec->query = voxgig_new_map();
    setp(spec->headers, "content-type",
         voxgig_new_string(GRAPHQL_CONTENT_TYPE));
  } else {
    spec->body = prepare_body_util(ctx);
    char* path = prepare_path_util(ctx);
    spec_set_path(spec, path);
  }

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "spec", spec_to_value(spec));
  }

  Spec* spec2 = prepare_auth_util(ctx, err);
  if (*err) return NULL;

  ctx->spec = spec2;
  return spec2;
}
