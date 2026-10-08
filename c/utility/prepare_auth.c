// prepare_auth utility (mirrors utility/prepare_auth.rs).
//
// GENERATED, not templated: where the credential goes - header, query or
// cookie, and under what name - is a fact about THIS API, and tm/ can only
// hold one answer. See PrepareAuth_c.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CRED_NAME "authorization"
#define OPTION_APIKEY "apikey"
#define NOT_FOUND "__NOTFOUND__"

// The client's auth.name option, when set, replaces the name the API
// declares. A run-time name is lower-cased into *owned, which the caller
// frees; NULL when that copy cannot be allocated.
static const char* auth_name(voxgig_value* options, char** owned) {
  *owned = NULL;
  voxgig_value* v = getpath2(options, "auth", "name");
  const char* name = voxgig_is_string(v) ? voxgig_as_string(v) : NULL;
  if (NULL == name || '\0' == name[0]) return CRED_NAME;
  size_t n = strlen(name);
  char* lower = (char*)malloc(n + 1);
  if (NULL == lower) return NULL;
  // ASCII rules, as a field name is ASCII: tolower follows the C locale.
  for (size_t i = 0; i <= n; i++) {
    char c = name[i];
    lower[i] = ('A' <= c && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
  }
  *owned = lower;
  return lower;
}

// a, sep and b joined, in a buffer allocated to fit; NULL when it cannot be.
static char* auth_join(const char* a, const char* sep, const char* b) {
  size_t n = strlen(a) + strlen(sep) + strlen(b) + 1;
  char* out = (char*)malloc(n);
  if (NULL != out) snprintf(out, n, "%s%s%s", a, sep, b);
  return out;
}

// Places or clears the credential under name, the one in effect.
static Spec* prepare_auth_as(Context* ctx, Spec* spec, voxgig_value* headers,
                             voxgig_value* options, const char* name,
                             PNError** err) {
  // A credential left under the declared name would travel beside the renamed one.
  if (0 != strcmp(name, CRED_NAME)) {
    voxgig_value* k = voxgig_new_string(CRED_NAME);
    voxgig_delprop(headers, k);
    voxgig_release(k);
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
    voxgig_value* k = voxgig_new_string(name);
    voxgig_delprop(headers, k);
    voxgig_release(k);
  } else {
    voxgig_value* prefix_v = getpath2(options, "auth", "prefix");
    const char* auth_prefix = voxgig_is_string(prefix_v) ? voxgig_as_string(prefix_v) : "";
    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
    if (auth_prefix[0] == '\0') {
      setp(headers, name, v_str(apikey_val));
    } else {
      char* joined = auth_join(auth_prefix, " ", apikey_val);
      if (NULL == joined) {
        *err = context_make_error(ctx, "auth_alloc", "Could not allocate the credential.");
        return NULL;
      }
      setp(headers, name, v_str(joined));
      free(joined);
    }
  }

  return spec;
}

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
    voxgig_value* k = voxgig_new_string(CRED_NAME);
    voxgig_delprop(headers, k);
    voxgig_release(k);
    return spec;
  }

  char* owned = NULL;
  const char* name = auth_name(options, &owned);
  if (NULL == name) {
    *err = context_make_error(ctx, "auth_alloc", "Could not allocate the credential name.");
    return NULL;
  }

  Spec* out = prepare_auth_as(ctx, spec, headers, options, name, err);
  free(owned);
  return out;
}
