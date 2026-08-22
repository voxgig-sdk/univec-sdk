package KOTLINPACKAGE.sdktest

// Custom utility overrides supplied via options.utility land on the utility
// object's custom map.

import java.util.function.Supplier

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.sdktest.FeatureHarness.fhMap

@Suppress("UNCHECKED_CAST")
class CustomUtilityTest {

  private fun util(tag: String): Supplier<MutableMap<String, Any?>> {
    return Supplier {
      val out = linkedMapOf<String, Any?>()
      out["util"] = tag
      out
    }
  }

  @Test
  fun basic() {
    val keys = arrayOf(
      "auth", "body", "contextify", "done", "error", "findparam", "fullurl",
      "headers", "method", "operator", "params", "query", "reqform",
      "request", "resbasic", "resbody", "resform", "resheaders", "response",
      "result", "spec",
    )

    val customUtils = linkedMapOf<String, Any?>()
    for (key in keys) {
      customUtils[key] = util(key.uppercase())
    }

    val client = UnivecSDK.testSDK(null, fhMap("apikey", "APIKEY01", "utility", customUtils))

    val u = client.getUtility()

    for (key in keys) {
      val fn = u.custom[key]
      assertTrue(fn is Supplier<*>, "expected custom utility $key to exist")
      val result = (fn as Supplier<MutableMap<String, Any?>>).get()
      assertEquals(key.uppercase(), result["util"], "custom utility $key")
    }
  }
}
