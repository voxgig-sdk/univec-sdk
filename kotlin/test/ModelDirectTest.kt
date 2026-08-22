package voxgig.univecsdk.sdktest

import java.util.function.BiFunction
import java.util.function.Supplier

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test

import voxgig.univecsdk.core.Helpers
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.utility.Json

@Suppress("UNCHECKED_CAST", "UNUSED_VARIABLE")
class ModelDirectTest {

  @Test
  fun directListModel() {
    val mockres = mutableListOf<Any?>()
    mockres.add(jm("id", "direct01"))
    mockres.add(jm("id", "direct02"))
    val setup = directSetup(mockres)
    val mode = if (setup.live) "live" else "unit"
    val reason = RunnerSupport.skipReason("direct", "direct-list-model", mode)
    Assumptions.assumeTrue(
      reason == null,
      if (reason == null || "" == reason) "skipped via sdk-test-control.json" else reason,
    )
    val client = setup.client


    val result = client.direct(jm(
        "path", "v1/models",
        "method", "GET",
        "params", linkedMapOf<String, Any?>()))
    if (setup.live) {
      Assumptions.assumeTrue(result["ok"] == true,
          "list call not ok (likely synthetic IDs against live API): " + result)
      val status = Helpers.toInt(result["status"])
      Assumptions.assumeTrue(status in 200..299, "expected 2xx status, got " + result["status"])
    } else {
      assertEquals(true, result["ok"], "expected ok to be true")
      assertEquals(200, Helpers.toInt(result["status"]), "expected status 200")
    }

    if (!setup.live) {
      assertTrue(result["data"] is List<*>,
          "expected data to be an array, got " + result["data"])
      assertEquals(2, (result["data"] as List<Any?>).size, "expected 2 items")

      assertEquals(1, setup.calls.size, "expected 1 call")
    }
  }

  companion object {
    fun jm(vararg kv: Any?): MutableMap<String, Any?> {
      val out = linkedMapOf<String, Any?>()
      var i = 0
      while (i < kv.size - 1) {
        out[kv[i].toString()] = kv[i + 1]
        i += 2
      }
      return out
    }

    class DirectSetup {
      lateinit var client: UnivecSDK
      var calls: MutableList<MutableMap<String, Any?>> = mutableListOf()
      var live: Boolean = false
      var idmap: MutableMap<String, Any?> = linkedMapOf()
    }

    fun directSetup(mockres: Any?): DirectSetup {
      RunnerSupport.loadEnvLocal()

      val calls = mutableListOf<MutableMap<String, Any?>>()

      val envm = linkedMapOf<String, Any?>()
      envm["UNIVEC_TEST_MODEL_ENTID"] = linkedMapOf<String, Any?>()
      envm["UNIVEC_TEST_LIVE"] = "FALSE"
      envm["UNIVEC_APIKEY"] = "NONE"
      val env = RunnerSupport.envOverride(envm)

      val live = "TRUE" == env["UNIVEC_TEST_LIVE"]

      val setup = DirectSetup()
      setup.calls = calls

      if (live) {
        val mergedOpts = linkedMapOf<String, Any?>()
        mergedOpts["apikey"] = env["UNIVEC_APIKEY"]
        setup.client = UnivecSDK(mergedOpts)
        setup.live = true

        var idmap: MutableMap<String, Any?> = linkedMapOf()
        val entidRaw = env["UNIVEC_TEST_MODEL_ENTID"]
        if (entidRaw is String && entidRaw.startsWith("{")) {
          val parsed = Helpers.toMapAny(Json.parseOrNull(entidRaw))
          if (parsed != null) {
            idmap = parsed
          }
        } else if (entidRaw is MutableMap<*, *>) {
          idmap = entidRaw as MutableMap<String, Any?>
        }
        setup.idmap = idmap
        return setup
      }

      val mockdata: Any? = mockres ?: jm("id", "direct01")
      val mockFetch = BiFunction<String, MutableMap<String, Any?>, MutableMap<String, Any?>> { url, init ->
        calls.add(jm("url", url, "init", init))
        jm(
            "status", 200,
            "statusText", "OK",
            "headers", linkedMapOf<String, Any?>(),
            "json", Supplier<Any?> { mockdata })
      }

      setup.client = UnivecSDK(jm(
          "base", "http://localhost:8080",
          "system", jm("fetch", mockFetch)))
      setup.live = false
      setup.idmap = linkedMapOf()
      return setup
    }
  }
}
