package KOTLINPACKAGE.sdktest

// Network-behaviour simulation over the offline mock transport. The `test`
// feature accepts an optional `net` config so unit tests can exercise slow,
// failing and offline conditions without a live server. These checks drive
// the transport through direct(), which needs no entity, so they run for
// every generated SDK regardless of its API shape.

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.sdktest.FeatureHarness.fhMap

class NetsimTest {

  @Test
  fun offlineSimulationFailsRequest() {
    val client = UnivecSDK.testSDK(fhMap("net", fhMap("offline", true)), null)
    val res = client.direct(fhMap("path", "/ping"))
    assertEquals(false, res["ok"], "offline network must fail the call: $res")
  }

  @Test
  fun failstatusSimulationSurfacesStatus() {
    val client = UnivecSDK.testSDK(fhMap("net", fhMap("failTimes", 1, "failStatus", 503)), null)
    val res = client.direct(fhMap("path", "/ping"))
    assertEquals(false, res["ok"], "expected failed call: $res")
    assertEquals(503, res["status"], "expected simulated 503")
  }

  @Test
  fun latencySimulationDelaysRequest() {
    val delay = 60
    val client = UnivecSDK.testSDK(fhMap("net", fhMap("latency", delay)), null)
    val start = System.currentTimeMillis()
    client.direct(fhMap("path", "/ping"))
    val elapsed = System.currentTimeMillis() - start
    // Generous lower bound to stay robust on slow CI.
    assertTrue(elapsed >= delay - 25, "expected >= ${delay - 25}ms latency, got ${elapsed}ms")
  }

  @Test
  fun plainTestSdkWorksWithoutNet() {
    val client = UnivecSDK.testSDK()
    assertNotNull(client, "expected a client")
  }
}
