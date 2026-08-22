// prepare_auth utility (mirrors utility/prepare_auth.rs).

#include "sdk.h"

#include <stdio.h>
#include <string.h>

#define HEADER_AUTH "authorization"
#define OPTION_APIKEY "apikey"
#define NOT_FOUND "__NOTFOUND__"

Spec* prepare_auth_util(Context* ctx, PNError** err) {
  *err = NULL;
  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "auth_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }

  voxgig_value* headers = spec->headers;
  voxgig_value* options = ctx->client ? sdk_options_map(ctx->client) : ctx->options;

  voxgig_value* auth = getp(options, "auth");
  if (v_is_noval(auth) || v_is_null(auth)) {
    voxgig_value* k = voxgig_new_string(HEADER_AUTH);
    voxgig_delprop(headers, k);
    voxgig_release(k);
    return spec;
  }

  voxgig_value* akey_key = voxgig_new_string(OPTION_APIKEY);
  voxgig_value* nf = voxgig_new_string(NOT_FOUND);
  voxgig_value* apikey = voxgig_getprop(options, akey_key, nf);
  voxgig_release(akey_key);
  voxgig_release(nf);

  bool skip;
  if (v_is_noval(apikey) || v_is_null(apikey)) {
    skip = true;
  } else if (voxgig_is_string(apikey)) {
    const char* s = voxgig_as_string(apikey);
    skip = (strcmp(s, NOT_FOUND) == 0 || s[0] == '\0');
  } else {
    skip = false;
  }

  if (skip) {
    voxgig_value* k = voxgig_new_string(HEADER_AUTH);
    voxgig_delprop(headers, k);
    voxgig_release(k);
  } else {
    voxgig_value* prefix_v = getpath2(options, "auth", "prefix");
    const char* auth_prefix = voxgig_is_string(prefix_v) ? voxgig_as_string(prefix_v) : "";
    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
    if (auth_prefix[0] == '\0') {
      setp(headers, HEADER_AUTH, v_str(apikey_val));
    } else {
      char buf[1024];
      snprintf(buf, sizeof(buf), "%s %s", auth_prefix, apikey_val);
      setp(headers, HEADER_AUTH, v_str(buf));
    }
  }

  return spec;
}
