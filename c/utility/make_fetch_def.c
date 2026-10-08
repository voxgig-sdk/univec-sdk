// make_fetch_def utility (mirrors utility/make_fetch_def.rs).

#include "sdk.h"

#include <stdlib.h>

voxgig_value* make_fetch_def_util(Context* ctx, PNError** err) {
  *err = NULL;
  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "fetchdef_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }

  if (!ctx->result) {
    ctx->result = result_new(voxgig_new_map());
  }

  spec_set_step(spec, "prepare");

  char* url = make_url_util(ctx, err);
  if (*err) return NULL;

  spec_set_url(spec, url);

  voxgig_value* fetchdef = voxgig_new_map();
  setp(fetchdef, "url", v_str(url));
  setp(fetchdef, "method", v_str(spec->method));
  setp(fetchdef, "headers", v_share(spec->headers));

  // A map or a list is JSON, and so is a scalar on a point that declares a
  // JSON body. Anything else goes as given.
  voxgig_value* body = spec->body;
  if (!v_is_noval(body)) {
    bool scalar = voxgig_is_string(body) || voxgig_is_number(body) || voxgig_is_bool(body);
    bool encode = voxgig_is_node(body) || (scalar && media_is_json_request(ctx->point));
    if (encode) {
      char* js = voxgig_jsonify(body, NULL);
      setp(fetchdef, "body", v_str(js ? js : ""));
      free(js);
    } else {
      setp(fetchdef, "body", v_share(body));
    }
  }

  return fetchdef;
}
