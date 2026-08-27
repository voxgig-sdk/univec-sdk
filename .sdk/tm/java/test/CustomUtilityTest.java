package JAVAPACKAGE.sdktest;

// Custom utility overrides supplied via options.utility land on the
// utility object's custom map. Mirrors tm/go/test/custom_utility_test.go.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import static JAVAPACKAGE.sdktest.FeatureHarness.fhMap;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.Supplier;

import org.junit.jupiter.api.Test;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.Utility;

@SuppressWarnings({"unchecked"})
public class CustomUtilityTest {

  static Supplier<Map<String, Object>> util(String tag) {
    return () -> {
      Map<String, Object> out = new LinkedHashMap<>();
      out.put("util", tag);
      return out;
    };
  }

  @Test
  public void basic() {
    String[] keys = {
        "auth", "body", "contextify", "done", "error", "findparam", "fullurl",
        "headers", "method", "operator", "params", "query", "reqform",
        "request", "resbasic", "resbody", "resform", "resheaders", "response",
        "result", "spec",
    };

    Map<String, Object> customUtils = new LinkedHashMap<>();
    for (String key : keys) {
      customUtils.put(key, util(key.toUpperCase()));
    }

    UnivecSDK client = UnivecSDK.testSDK(null, fhMap(
        "apikey", "APIKEY01",
        "utility", customUtils));

    Utility u = client.getUtility();

    for (String key : keys) {
      Object fn = u.custom.get(key);
      assertTrue(fn instanceof Supplier, "expected custom utility " + key + " to exist");
      Map<String, Object> result = ((Supplier<Map<String, Object>>) fn).get();
      assertEquals(key.toUpperCase(), result.get("util"),
          "custom utility " + key);
    }
  }

  // The half the test above cannot see. Those keys are ALIASES - `auth`,
  // `body`, `spec` - and no utility member has those names, so landing in
  // custom is the right outcome for them and the assertion passes whether or
  // not overriding works at all.
  //
  // A key that DOES name a member must replace it. That is the documented
  // contract, it is what ts does, and it was silently absent here: every entry
  // went to custom, which nothing reads, so `utility: {"fetcher": ...}` did
  // nothing while ts honoured it.
  @Test
  public void aRealUtilityMemberIsReplacedNotShelved() {
    int[] reached = {0};
    Utility.FetcherFn scripted = (ctx, fullurl, fetchdef) -> {
      reached[0]++;
      Map<String, Object> out = new LinkedHashMap<>();
      out.put("status", 200);
      out.put("statusText", "OK");
      out.put("headers", new LinkedHashMap<String, Object>());
      out.put("body", "{}");
      return out;
    };

    // The plain constructor, not testSDK. The `test` feature is
    // transport: 'base' - it REPLACES the transport by design - so a client in
    // test mode would shadow the scripted fetcher and this would assert
    // nothing.
    UnivecSDK client = new UnivecSDK(fhMap(
        "utility", fhMap("fetcher", scripted)));

    Utility u = client.getUtility();

    assertNotNull(u.fetcher, "fetcher is null");
    assertFalse(u.custom.containsKey("fetcher"),
        "fetcher was shelved in custom instead of replacing the member");

    // Behaviour, not identity: a lambda cannot be compared, so drive it.
    Context ctx = u.makeContext.apply(
        new LinkedHashMap<String, Object>(), client.getRootCtx());
    u.fetcher.fetch(ctx, "http://example.test/probe", new LinkedHashMap<String, Object>());
    assertEquals(1, reached[0], "the scripted fetcher was not installed");
  }

  // An unknown key must still be attached rather than dropped, so the two
  // halves cannot be satisfied by a switch that also swallows extras.
  @Test
  public void anUnknownKeyIsStillAttached() {
    UnivecSDK client = new UnivecSDK(fhMap(
        "utility", fhMap("notAUtilityMember", (Supplier<String>) () -> "EXTRA")));
    assertTrue(client.getUtility().custom.containsKey("notAUtilityMember"),
        "an unknown utility key was dropped instead of kept in custom");
  }
}
