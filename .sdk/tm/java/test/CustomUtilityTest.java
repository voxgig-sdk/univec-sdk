package JAVAPACKAGE.sdktest;

// Custom utility overrides supplied via options.utility land on the
// utility object's custom map. Mirrors tm/go/test/custom_utility_test.go.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import static JAVAPACKAGE.sdktest.FeatureHarness.fhMap;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.Supplier;

import org.junit.jupiter.api.Test;

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
}
