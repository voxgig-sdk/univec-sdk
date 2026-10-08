// Generated instance test for the model entity.

#include "ctest.h"

int main(void) {
  UnivecSDK* sdk = test_sdk(NULL, NULL);
  CHECK(sdk != NULL, "sdk constructed");

  Entity* e = univec_model(sdk, NULL);
  CHECK(e != NULL, "entity instance");
  CHECK_STR_EQ(e->vt->get_name(e), "model", "entity get_name");

  // stream(): runs the list op through the full pipeline and returns a List
  // of items. Seed two entities via test mode; with the streaming feature
  // active it yields the feature's incremental items, else it falls back to
  // the materialised items — either way every item is yielded.
  {
    voxgig_value* seed = cmap(1, "entity",
      cmap(1, "model",
        cmap(2,
          "strm01", cmap(1, "id", v_str("strm01")),
          "strm02", cmap(1, "id", v_str("strm02")))));
    voxgig_value* sdkopts = cmap(1, "feature",
      cmap(1, "streaming", cmap(1, "active", v_bool(true))));

    UnivecSDK* strsdk = test_sdk(seed, sdkopts);
    Entity* se = univec_model(strsdk, NULL);
    PNError* serr = NULL;
    voxgig_value* items = model_stream(se, "list", NULL, NULL, &serr);
    CHECK(serr == NULL, "stream: no error");
    CHECK(v_is_list(items), "stream: returns a list");
    CHECK_INT_EQ((int64_t)voxgig_as_list(items)->len, 2, "stream: yields both items");

    // Fallback: streaming inactive still yields both materialised items.
    UnivecSDK* plainsdk = test_sdk(seed, NULL);
    Entity* pe = univec_model(plainsdk, NULL);
    PNError* perr = NULL;
    voxgig_value* pitems = model_stream(pe, "list", NULL, NULL, &perr);
    CHECK(perr == NULL, "stream fallback: no error");
    CHECK_INT_EQ((int64_t)voxgig_as_list(pitems)->len, 2, "stream fallback: yields both items");
  }

  {
    voxgig_value* offline = cmap(1, "net", cmap(1, "offline", v_bool(true)));
    PNError* ferr = NULL;
    Entity* fe = univec_model(test_sdk(offline, NULL), NULL);
    voxgig_value* fitems = model_stream(fe, "list", NULL, NULL, &ferr);
    CHECK(NULL == fitems && NULL != ferr && NULL != strstr(ferr->msg, "offline"),
      "stream: a failed operation fails the stream");

    PNError* qerr = NULL;
    Entity* qe = univec_model(test_sdk(offline, NULL), NULL);
    model_stream(qe, "list", NULL, cmap(1, "ctrl", cmap(1, "throw", v_bool(false))), &qerr);
    CHECK(NULL == qerr, "stream: under throw false a failed stream ends");

    if (!v_is_noval(getp(getp(shared_config(), "feature"), "rbac"))) {
      PNError* derr = NULL;
      Entity* de = univec_model(test_sdk(NULL, cmap(1, "feature",
        cmap(1, "rbac", cmap(2, "active", v_bool(true), "deny", v_bool(true))))), NULL);
      model_stream(de, "list", NULL, NULL, &derr);
      CHECK(NULL != derr && 0 == strcmp(derr->code, "rbac_denied"),
        "stream: a denied operation fails the stream");
    }
  }

  {
    voxgig_value* explain = voxgig_new_map();
    voxgig_value* ctrl = cmap(1, "explain", v_share(explain));
    PNError* cerr = NULL;
    Entity* ce = univec_model(test_sdk(NULL, NULL), NULL);
    model_stream(ce, "list", NULL, cmap(1, "ctrl", v_share(ctrl)), &cerr);
    CHECK(NULL == cerr && v_is_noval(getp(ctrl, "stream")),
      "stream: the caller's ctrl gains no key");
    CHECK(0 < voxgig_as_map(explain)->len, "stream: the caller's explain record is filled");
  }

  if (!v_is_noval(getp(getp(shared_config(), "feature"), "validate"))) {
    PNError* verr = NULL;
    Entity* ve = univec_model(test_sdk(NULL, cmap(1, "feature",
      cmap(1, "validate", cmap(1, "active", v_bool(true))))), NULL);
    ve->vt->list(ve, cmap(1, "executionProvider", v_num(1)), NULL, &verr);
    CHECK(NULL != verr && 0 == strcmp(verr->code, "validate_failed"),
      "an invalid request fails with validate_failed");
  }

  TEST_SUMMARY("model_entity");
}
