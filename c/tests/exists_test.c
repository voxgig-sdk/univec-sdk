// Generated existence test: the SDK constructs in test mode.

#include "ctest.h"

int main(void) {
  UnivecSDK* testsdk = test_sdk(NULL, NULL);
  CHECK(testsdk != NULL, "test_sdk returns a client");
  CHECK_STR_EQ(testsdk->mode, "test", "test_sdk mode is test");
  TEST_SUMMARY("exists");
}
