package JAVAPACKAGE.sdktest;

// Network-behaviour simulation over the offline mock transport. The `test`
// feature accepts an optional `net` config so unit tests can exercise slow,
// failing and offline conditions without a live server. These checks drive
// the transport through direct(), which needs no entity, so they run for
// every generated SDK regardless of its API shape. Mirrors
// tm/go/test/netsim_test.go.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import static JAVAPACKAGE.sdktest.FeatureHarness.fhMap;

import java.util.Map;

import org.junit.jupiter.api.Test;

import JAVAPACKAGE.core.UnivecSDK;

public class NetsimTest {

  @Test
  public void offlineSimulationFailsRequest() {
    UnivecSDK client = UnivecSDK.testSDK(fhMap(
        "net", fhMap("offline", true)), null);
    Map<String, Object> res = client.direct(fhMap("path", "/ping"));
    assertEquals(false, res.get("ok"), "offline network must fail the call: " + res);
  }

  @Test
  public void failstatusSimulationSurfacesStatus() {
    UnivecSDK client = UnivecSDK.testSDK(fhMap(
        "net", fhMap("failTimes", 1, "failStatus", 503)), null);
    Map<String, Object> res = client.direct(fhMap("path", "/ping"));
    assertEquals(false, res.get("ok"), "expected failed call: " + res);
    assertEquals(503, res.get("status"), "expected simulated 503");
  }

  @Test
  public void latencySimulationDelaysRequest() {
    int delay = 60;
    UnivecSDK client = UnivecSDK.testSDK(fhMap(
        "net", fhMap("latency", delay)), null);
    long start = System.currentTimeMillis();
    client.direct(fhMap("path", "/ping"));
    long elapsed = System.currentTimeMillis() - start;
    // Generous lower bound to stay robust on slow CI.
    assertTrue(elapsed >= delay - 25,
        "expected >= " + (delay - 25) + "ms latency, got " + elapsed + "ms");
  }

  @Test
  public void plainTestSdkWorksWithoutNet() {
    UnivecSDK client = UnivecSDK.testSDK();
    assertNotNull(client, "expected a client");
  }
}
