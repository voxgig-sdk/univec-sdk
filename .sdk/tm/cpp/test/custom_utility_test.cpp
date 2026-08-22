// Univec SDK — custom utility overrides supplied via options.utility
// land on the utility object's custom map (mirrors java
// test/CustomUtilityTest.java). This exercises value-semantics gotcha #8:
// the struct clone in makeOptions must NOT drop the function (Injector)
// values, so each override is still callable after client construction.

#include "harness.hpp"

using namespace sdk;
using namespace sdk::fh;

// A callable override: an Injector that ignores its args and returns { util: tag }.
static Value mkutil(const std::string& tag) {
  vs::Injector fn = [tag](vs::Injection&, const Value&, const std::string&, const Value&) -> Value {
    return vmap({{"util", Value(tag)}});
  };
  return Value(fn);
}

static std::string upper(const std::string& s) {
  std::string o = s;
  for (auto& c : o) c = static_cast<char>(std::toupper((unsigned char)c));
  return o;
}

static void basic() {
  const std::vector<std::string> keys = {
      "auth", "body", "contextify", "done", "error", "findparam", "fullurl",
      "headers", "method", "operator", "params", "query", "reqform",
      "request", "resbasic", "resbody", "resform", "resheaders", "response",
      "result", "spec",
  };

  Value customUtils = vmap();
  for (const auto& k : keys) map_put(customUtils, k, mkutil(upper(k)));

  auto client = UnivecSDK::testSDK(
      Value::undef(),
      fhMap({{"apikey", Value("APIKEY01")}, {"utility", customUtils}}));

  UtilityPtr u = client->getUtility();

  for (const auto& k : keys) {
    Value fn = getp(u->custom, k);
    ASSERT_TRUE(fn.is_injector(), "expected custom utility " + k + " to exist");
    if (fn.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      Value r = fn.as_injector()(inj, Value::undef(), std::string(""), Value::undef());
      ASSERT_EQ_VAL(getp(r, "util"), Value(upper(k)), "custom utility " + k);
    }
  }
}

int main() {
  T_RUN(basic);
  return sdktest::summary("custom_utility_test");
}
