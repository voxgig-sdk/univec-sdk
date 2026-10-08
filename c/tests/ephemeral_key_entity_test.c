// Generated instance test for the ephemeral_key entity.

#include "ctest.h"

int main(void) {
  UnivecSDK* sdk = test_sdk(NULL, NULL);
  CHECK(sdk != NULL, "sdk constructed");

  Entity* e = univec_ephemeral_key(sdk, NULL);
  CHECK(e != NULL, "entity instance");
  CHECK_STR_EQ(e->vt->get_name(e), "ephemeral_key", "entity get_name");

  if (!v_is_noval(getp(getp(shared_config(), "feature"), "validate"))) {
    PNError* verr = NULL;
    Entity* ve = univec_ephemeral_key(test_sdk(NULL, cmap(1, "feature",
      cmap(1, "validate", cmap(1, "active", v_bool(true))))), NULL);
    ve->vt->create(ve, cmap(4, "dailyLimit", v_str("x"), "dailyUsed", v_num(1), "key", v_str("x"), "resetsAt", v_str("x")), NULL, &verr);
    CHECK(NULL != verr && 0 == strcmp(verr->code, "validate_failed"),
      "an invalid request fails with validate_failed");
  }

  TEST_SUMMARY("ephemeral_key_entity");
}
