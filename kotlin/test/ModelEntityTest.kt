package voxgig.univecsdk.sdktest

import java.nio.file.Files
import java.nio.file.Paths

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test

import voxgig.univecsdk.core.Config
import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Helpers
import voxgig.univecsdk.core.SdkEntity
import voxgig.univecsdk.core.SdkError
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.feature.BaseFeature
import voxgig.univecsdk.utility.Json
import voxgig.univecsdk.utility.struct.Struct

@Suppress("UNCHECKED_CAST", "UNUSED_VARIABLE", "UNUSED_VALUE")
class ModelEntityTest {

  // main.kit.test.live.strict is true (the default is true): a live
  // request that fails, or a live test missing an input it needs,
  // fails the test.
  // An account with no record for a test to read skips it either way.
  private val LIVE_STRICT = true

  @Test
  fun instance() {
    val testsdk = UnivecSDK.testSDK()
    val ent = testsdk.model(null)
    assertNotNull(ent, "expected non-null model entity")
  }

  @Test
  fun basic() {
    val setup = modelBasicSetup(null)
    // Per-op sdk-test-control.json skip.
    val mode = if (setup.live) "live" else "unit"
    for (op in arrayOf<String>("list")) {
      val reason = RunnerSupport.skipReason("entityOp", "model.$op", mode)
      Assumptions.assumeTrue(
        reason == null,
        if (reason == null || "" == reason) "skipped via sdk-test-control.json" else reason,
      )
    }
    val client = setup.client

    // Bootstrap entity data from existing test data (no create step in flow).
    val modelRef01DataRaw = Struct.items(Helpers.toMapAny(
        Struct.getpath(setup.data, "existing.model")))
    val modelRef01Data: MutableMap<String, Any?> = if (modelRef01DataRaw.isEmpty())
        linkedMapOf() else (Helpers.toMapAny(modelRef01DataRaw[0][1]) ?: linkedMapOf())

    // LIST
    val modelRef01Ent = client.model(null)
    val modelRef01Match = linkedMapOf<String, Any?>()

    val modelRef01ListResult = modelRef01Ent.list(modelRef01Match, null)
    assertTrue(modelRef01ListResult is List<*>,
        "expected list result to be an array, got " + modelRef01ListResult)

  }

  @Test
  fun stream() {
    val streamingActive = linkedMapOf<String, Any?>(
      "feature" to linkedMapOf<String, Any?>(
        "streaming" to linkedMapOf<String, Any?>("active" to true),
      ),
    )
    val setup = modelBasicSetup(streamingActive)
    Assumptions.assumeFalse(
      setup.live,
      "stream test streams the seeded fixture data (unit mode only)",
    )

    val ent = setup.client.model(null)
    val match = linkedMapOf<String, Any?>()

    // Materialised list result for the same op.
    val listedResult = ent.list(match, null)
    val listed = (listedResult as? List<Any?>) ?: emptyList<Any?>()

    // stream("list") yields items via the streaming feature's iterator.
    val streamed = ent.stream("list", match, null).toList()
    assertTrue(streamed.size > 0, "expected stream to yield items")
    assertEquals(listed.size, streamed.size, "expected stream to match list count")

    // Fallback: with streaming inactive, stream still yields the materialised
    // items.
    val setup2 = modelBasicSetup(null)
    val ent2 = setup2.client.model(null)
    val streamed2 = ent2.stream("list", match, null).toList()
    assertEquals(listed.size, streamed2.size, "expected fallback stream to match list")
  }

  private fun hasFeature(name: String): Boolean {
    val fm = Helpers.toMapAny(Config.sharedConfig()["feature"])
    return fm != null && fm[name] != null
  }

  class FailHook : BaseFeature("failhook", "0.0.1", true) {
    var unexpected = 0
    override fun preSpec(ctx: Context) { throw RuntimeException("model hook failed") }
    override fun preUnexpected(ctx: Context) { unexpected++ }
  }

  @Test
  fun streamError() {
    val offline = linkedMapOf<String, Any?>("net" to linkedMapOf<String, Any?>("offline" to true))
    val err = assertThrows(RuntimeException::class.java) {
      UnivecSDK.testSDK(offline, null).model(null).stream("list", null, null).toList()
    }
    assertTrue(err.message.orEmpty().contains("offline"), err.message)

    UnivecSDK.testSDK(offline, null).model(null).stream("list", null,
      linkedMapOf<String, Any?>("ctrl" to linkedMapOf<String, Any?>("throw" to false))).toList()

    if (hasFeature("rbac")) {
      val denied = UnivecSDK.testSDK(null, linkedMapOf<String, Any?>(
        "feature" to linkedMapOf<String, Any?>(
          "rbac" to linkedMapOf<String, Any?>("active" to true, "deny" to true))))
      val denyerr = assertThrows(SdkError::class.java) {
        denied.model(null).stream("list", null, null).toList()
      }
      assertEquals("rbac_denied", denyerr.code)
    }
  }

  @Test
  fun streamCtrl() {
    val explain = linkedMapOf<String, Any?>()
    val ctrl = linkedMapOf<String, Any?>("explain" to explain)
    UnivecSDK.testSDK().model(null).stream("list", null,
      linkedMapOf<String, Any?>("ctrl" to ctrl)).toList()
    assertEquals(listOf("explain"), ctrl.keys.toList())
    assertTrue(explain === ctrl["explain"] && explain.isNotEmpty())
  }

  @Test
  fun unexpected() {
    val hook = FailHook()
    val client = UnivecSDK(linkedMapOf<String, Any?>(
      "feature" to linkedMapOf<String, Any?>("test" to linkedMapOf<String, Any?>("active" to true)),
      "extend" to mutableListOf<Any?>(hook)))

    val err = assertThrows(RuntimeException::class.java) {
      client.model(null).list(null, null)
    }
    assertTrue(err.message.orEmpty().contains("hook failed"), err.message)
    assertTrue(0 < hook.unexpected)

    val fired = hook.unexpected
    client.model(null).list(null, linkedMapOf<String, Any?>("throw" to false))
    assertTrue(fired < hook.unexpected)
  }

  @Test
  fun validate() {
    Assumptions.assumeTrue(hasFeature("validate"), "feature not present in this SDK: validate")
    val client = UnivecSDK.testSDK(null, linkedMapOf<String, Any?>(
      "feature" to linkedMapOf<String, Any?>(
        "validate" to linkedMapOf<String, Any?>("active" to true))))
    val err = assertThrows(SdkError::class.java) {
      client.model(null).list(linkedMapOf<String, Any?>("executionProvider" to 1), null)
    }
    assertEquals("validate_failed", err.code)
  }

  companion object {
    fun modelBasicSetup(extra: MutableMap<String, Any?>?): RunnerSupport.EntityTestSetup {
      RunnerSupport.loadEnvLocal()

      val entityData: MutableMap<String, Any?>
      try {
        val entityDataSource = Files.readString(Paths.get(
            "..", ".sdk", "test", "entity", "model", "ModelTestData.json"))
        entityData = Helpers.toMapAny(Json.parse(entityDataSource)) ?: linkedMapOf()
      } catch (e: Exception) {
        throw AssertionError("failed to read model test data: " + e.message, e)
      }

      val options = linkedMapOf<String, Any?>()
      options["entity"] = entityData["existing"]

      var client = UnivecSDK.testSDK(options, extra)

      // Generate idmap via transform, matching TS pattern.
      val idnames = mutableListOf<Any?>()
      idnames.add("model01")
      idnames.add("model02")
      idnames.add("model03")
      val idmap = Struct.transform(idnames, Json.parse(
          "{\"`\$PACK`\": [\"\", {" +
          "\"`\$KEY`\": \"`\$COPY`\"," +
          "\"`\$VAL`\": [\"`\$FORMAT`\", \"upper\", \"`\$COPY`\"]" +
          "}]}"))

      // Whether *_ENTID supplied the idmap, read before envOverride consumes it.
      val entidEnvRaw = RunnerSupport.getenv("UNIVEC_TEST_MODEL_ENTID")
      val idmapOverridden = entidEnvRaw != null && entidEnvRaw.trim().startsWith("{")

      val envm = linkedMapOf<String, Any?>()
      envm["UNIVEC_TEST_MODEL_ENTID"] = idmap
      envm["UNIVEC_TEST_LIVE"] = "FALSE"
      envm["UNIVEC_TEST_EXPLAIN"] = "FALSE"
      envm["UNIVEC_APIKEY"] = "NONE"
      val env = RunnerSupport.envOverride(envm)

      var idmapResolved = Helpers.toMapAny(env["UNIVEC_TEST_MODEL_ENTID"])
      if (idmapResolved == null) {
        idmapResolved = Helpers.toMapAny(idmap) ?: linkedMapOf()
      }

      val live = "TRUE" == env["UNIVEC_TEST_LIVE"]
      if (live) {
        val liveOpts = linkedMapOf<String, Any?>()
        liveOpts["apikey"] = env["UNIVEC_APIKEY"]
        val mergedOpts = Struct.merge(Struct.jt(liveOpts, extra))
        client = UnivecSDK(Helpers.toMapAny(mergedOpts))
      }

      val setup = RunnerSupport.EntityTestSetup()
      setup.client = client
      setup.data = entityData
      setup.idmap = idmapResolved
      setup.env = env
      setup.explain = "TRUE" == env["UNIVEC_TEST_EXPLAIN"]
      setup.live = live
      setup.syntheticOnly = live && !idmapOverridden
      setup.now = System.currentTimeMillis()
      return setup
    }
  }
}
