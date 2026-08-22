// Generated existence test: the SDK constructs in test mode.

#include "testlib.hpp"

using namespace sdk;

static void exists_test_mode() {
  auto testsdk = UnivecSDK::testSDK();
  ASSERT_NOTNULL(testsdk, "expected non-null SDK");
  ASSERT_EQ(testsdk->mode, std::string("test"), "expected test mode");
}

int main() {
  T_RUN(exists_test_mode);
  return sdktest::summary("exists_test");
}
