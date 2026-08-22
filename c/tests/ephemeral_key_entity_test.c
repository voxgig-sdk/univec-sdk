// Generated instance test for the ephemeral_key entity.

#include "ctest.h"

int main(void) {
  UnivecSDK* sdk = test_sdk(NULL, NULL);
  CHECK(sdk != NULL, "sdk constructed");

  Entity* e = univec_ephemeral_key(sdk, NULL);
  CHECK(e != NULL, "entity instance");
  CHECK_STR_EQ(e->vt->get_name(e), "ephemeral_key", "entity get_name");

  TEST_SUMMARY("ephemeral_key_entity");
}
