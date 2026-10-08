// Univec SDK - a templated base URL takes each {name} from the `server`
// option. A missing or empty value fails construction; test mode fills in
// test-<name>.

#include "harness.hpp"

using namespace sdk;

// A variable no API declares, so the API's own server defaults cannot fill it.
static const std::string BASE = "https://api.example.test/bot{zzvar}";

static Value baseOf(const std::shared_ptr<UnivecSDK>& client) {
  return getp(client->optionsMap(), "base");
}

static void a_missing_or_empty_value_fails_construction() {
  for (const Value& server : {vmap(), vmap({{"zzvar", Value("")}})}) {
    SdkErrorPtr err;
    try {
      std::make_shared<UnivecSDK>(vmap({{"base", Value(BASE)}, {"server", server}}));
    } catch (const SdkErrorPtr& e) {
      err = e;
    }
    ASSERT_TRUE((bool)err, "construction should fail without a value for zzvar");
    if (err) {
      ASSERT_EQ(err->code, std::string("server_var_required"), "the error carries its code");
      ASSERT_TRUE(std::string::npos != err->msg.find("the server variable 'zzvar' is required"), err->msg);
      ASSERT_TRUE(std::string::npos != err->msg.find(BASE), err->msg);
    }
  }
}

static void a_server_value_fills_the_base() {
  auto client = std::make_shared<UnivecSDK>(vmap({
    {"base", Value(BASE)}, {"server", vmap({{"zzvar", Value("T1")}})},
  }));
  ASSERT_EQ_VAL(baseOf(client), Value("https://api.example.test/botT1"), "a server value fills the base");
}

static void test_mode_fills_the_base() {
  auto client = std::make_shared<UnivecSDK>(vmap({
    {"base", Value(BASE)}, {"test", vmap({{"active", Value(true)}})},
  }));
  ASSERT_EQ_VAL(baseOf(client), Value("https://api.example.test/bottest-zzvar"),
                "the test option fills test-<name>");

  auto mock = UnivecSDK::testSDK(Value::undef(), vmap({{"base", Value(BASE)}}));
  ASSERT_EQ_VAL(baseOf(mock), Value("https://api.example.test/bottest-zzvar"),
                "the test feature fills test-<name>");
}

int main() {
  T_RUN(a_missing_or_empty_value_fails_construction);
  T_RUN(a_server_value_fills_the_base);
  T_RUN(test_mode_fills_the_base);
  return sdktest::summary("server_variable_test");
}
