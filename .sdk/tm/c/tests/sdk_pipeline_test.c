// Behavioral pipeline test (template; same for every API). Drives the public
// SDK through a mock system.fetch transport, and exercises the retry feature
// end-to-end. Uses only the generic SDK surface (no per-entity names).

#include "ctest.h"

#include <stdlib.h>

static int CALLS = 0;

// Mock transport: always 200 with {id:"direct01"}. args = [url, fetchdef].
static voxgig_value* mock_ok(void* ud, voxgig_value* args) {
  (void)ud; (void)args;
  CALLS++;
  voxgig_value* data = cmap(1, "id", v_str("direct01"));
  return cmap(4,
    "status", v_num(200),
    "statusText", v_str("OK"),
    "headers", v_map(),
    "json", json_thunk(data));
}

// Mock transport: 503 for the first two calls, then 200 (drives retry).
static voxgig_value* mock_retry(void* ud, voxgig_value* args) {
  (void)ud; (void)args;
  CALLS++;
  int status = CALLS < 3 ? 503 : 200;
  voxgig_value* data = cmap(1, "id", v_str("r"));
  return cmap(4,
    "status", v_num(status),
    "statusText", v_str("x"),
    "headers", v_map(),
    "json", json_thunk(data));
}

// No-op injected sleep so the retry test does not actually wait.
static voxgig_value* nosleep(void* ud, voxgig_value* arg) {
  (void)ud; (void)arg;
  return v_undef();
}

static bool ok_true(voxgig_value* res) {
  voxgig_value* okv = getp(res, "ok");
  return voxgig_is_bool(okv) && voxgig_as_bool(okv);
}

int main(void) {
  // 1. test_sdk constructs in test mode.
  UnivecSDK* t = test_sdk(NULL, NULL);
  CHECK(t != NULL, "test_sdk returns a client");
  CHECK_STR_EQ(t->mode, "test", "test_sdk mode is test");

  // 2. direct() via a mock transport.
  CALLS = 0;
  voxgig_value* opts = cmap(2,
    "base", v_str("http://localhost:8080"),
    "system", cmap(1, "fetch", vfn(mock_ok, NULL)));
  UnivecSDK* sdk = projectname_sdk_new(opts);
  CHECK_STR_EQ(sdk->mode, "live", "plain client mode is live");

  PNError* err = NULL;
  voxgig_value* res = sdk_direct(sdk,
    cmap(2, "path", v_str("/thing"), "method", v_str("GET")), &err);
  CHECK(err == NULL, "direct: no error out-param");
  CHECK(ok_true(res), "direct: ok is true");
  CHECK_INT_EQ(to_int(getp(res, "status")), 200, "direct: status 200");
  CHECK_STR_EQ(get_str(getp(res, "data"), "id"), "direct01", "direct: data.id");
  CHECK_INT_EQ(CALLS, 1, "direct: transport called once");

  // 3. retry feature: 503,503,200 -> three transport calls, ok.
  CALLS = 0;
  voxgig_value* ropts = cmap(3,
    "base", v_str("http://localhost:8080"),
    "system", cmap(1, "fetch", vfn(mock_retry, NULL)),
    "feature", cmap(1, "retry", cmap(3,
      "active", v_bool(true),
      "minDelay", v_num(0),
      "sleep", vfn(nosleep, NULL))));
  UnivecSDK* rsdk = projectname_sdk_new(ropts);
  PNError* rerr = NULL;
  voxgig_value* rres = sdk_direct(rsdk,
    cmap(2, "path", v_str("/thing"), "method", v_str("GET")), &rerr);
  CHECK(rerr == NULL, "retry: no error out-param");
  CHECK(ok_true(rres), "retry: ok is true after retries");
  CHECK_INT_EQ(to_int(getp(rres, "status")), 200, "retry: final status 200");
  CHECK_INT_EQ(CALLS, 3, "retry: transport called three times");

  TEST_SUMMARY("sdk_pipeline");
}
