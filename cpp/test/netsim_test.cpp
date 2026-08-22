// Univec SDK — network-simulation tests over the offline mock transport
// (mirrors java test/NetsimTest.java). The `test` feature's optional `net`
// block exercises slow / failing / offline conditions with no live server;
// these drive the transport through direct(), so they run for every SDK.

#include <chrono>

#include "harness.hpp"

using namespace sdk;
using namespace sdk::fh;

static void offline_simulation_fails_request() {
  auto client = UnivecSDK::testSDK(fhMap({{"net", fhMap({{"offline", Value(true)}})}}), Value::undef());
  Value res = client->direct(fhMap({{"path", Value("/ping")}}));
  ASSERT_EQ_VAL(getp(res, "ok"), Value(false), "offline network must fail the call");
}

static void failstatus_simulation_surfaces_status() {
  auto client = UnivecSDK::testSDK(
      fhMap({{"net", fhMap({{"failTimes", Value(1)}, {"failStatus", Value(503)}})}}), Value::undef());
  Value res = client->direct(fhMap({{"path", Value("/ping")}}));
  ASSERT_EQ_VAL(getp(res, "ok"), Value(false), "expected failed call");
  ASSERT_EQ(Helpers::toInt(getp(res, "status")), 503, "expected simulated 503");
}

static void latency_simulation_delays_request() {
  int delay = 60;
  auto client = UnivecSDK::testSDK(fhMap({{"net", fhMap({{"latency", Value(delay)}})}}), Value::undef());
  auto start = std::chrono::steady_clock::now();
  client->direct(fhMap({{"path", Value("/ping")}}));
  auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now() - start).count();
  ASSERT_TRUE(elapsed >= delay - 25, "expected >= " + std::to_string(delay - 25) + "ms latency");
}

static void plain_test_sdk_works_without_net() {
  auto client = UnivecSDK::testSDK();
  ASSERT_NOTNULL(client, "expected a client");
}

int main() {
  T_RUN(offline_simulation_fails_request);
  T_RUN(failstatus_simulation_surfaces_status);
  T_RUN(latency_simulation_delays_request);
  T_RUN(plain_test_sdk_works_without_net);
  return sdktest::summary("netsim_test");
}
