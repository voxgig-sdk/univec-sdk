// Default transport (mirrors utility/fetcher.rs). The C target ships no HTTP
// client dependency: live requests without a caller-supplied system.fetch
// return a transport error. All tests run in test mode (fetch blocked) or
// inject a system.fetch mock, so the live path is never exercised by tests.

#include "sdk.h"

#include <stdio.h>
#include <string.h>

static voxgig_value* default_http_fetch(const char* fullurl, voxgig_value* fetchdef,
                                        Context* ctx, PNError** err) {
  (void)fetchdef;
  char buf[512];
  snprintf(buf, sizeof(buf),
           "live HTTP transport not available in the C SDK (URL was: \"%s\"); "
           "supply options.system.fetch",
           fullurl);
  *err = context_make_error(ctx, "fetch_transport", buf);
  return NULL;
}

voxgig_value* fetcher_util(Fetcher* self, Context* ctx, const char* fullurl,
                           voxgig_value* fetchdef, PNError** err) {
  (void)self;
  *err = NULL;

  UnivecSDK* client = ctx->client;
  if (!client) {
    *err = context_make_error(ctx, "fetch_no_client", "Expected context client.");
    return NULL;
  }

  const char* mode = client->mode;
  if (strcmp(mode, "live") != 0) {
    char buf[512];
    snprintf(buf, sizeof(buf), "Request blocked by mode: \"%s\" (URL was: \"%s\")",
             mode, fullurl);
    *err = context_make_error(ctx, "fetch_mode_block", buf);
    return NULL;
  }

  voxgig_value* options = sdk_options_map(client);
  voxgig_value* testactive;
  {
    const char* keys[4] = {"feature", "test", "active", NULL};
    testactive = getpath_c(options, keys);
  }
  if (voxgig_is_bool(testactive) && voxgig_as_bool(testactive)) {
    char buf[512];
    snprintf(buf, sizeof(buf),
             "Request blocked as test feature is active (URL was: \"%s\")", fullurl);
    *err = context_make_error(ctx, "fetch_test_block", buf);
    return NULL;
  }

  voxgig_value* sys_fetch = getpath2(options, "system", "fetch");

  if (v_is_noval(sys_fetch) || v_is_null(sys_fetch)) {
    return default_http_fetch(fullurl, fetchdef, ctx, err);
  }

  if (voxgig_is_func(sys_fetch)) {
    // Caller-supplied transport: called with [url, fetchdef]; returns a
    // transport-shaped response map (an "__err__" entry signals failure).
    voxgig_value* args = clist(2, v_str(fullurl), v_share(fetchdef));
    voxgig_value* out = call_vfn(sys_fetch, args);
    const char* emsg = get_str(out, "__err__");
    if (emsg) {
      *err = context_make_error(ctx, "fetch_system", emsg);
      return NULL;
    }
    return out;
  }

  *err = context_make_error(ctx, "fetch_invalid", "system.fetch is not a valid function");
  return NULL;
}
