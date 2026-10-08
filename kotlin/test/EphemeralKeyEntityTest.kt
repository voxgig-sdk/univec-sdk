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
class EphemeralKeyEntityTest {

  // main.kit.test.live.strict is true (the default is true): a live
  // request that fails, or a live test missing an input it needs,
  // fails the test.
  // An account with no record for a test to read skips it either way.
  private val LIVE_STRICT = true

  @Test
  fun instance() {
    val testsdk = UnivecSDK.testSDK()
    val ent = testsdk.ephemeralKey(null)
    assertNotNull(ent, "expected non-null ephemeral_key entity")
  }

  @Test
  fun basic() {
    val setup = ephemeralKeyBasicSetup(null)
    // Per-op sdk-test-control.json skip.
    val mode = if (setup.live) "live" else "unit"
    for (op in arrayOf<String>("create")) {
      val reason = RunnerSupport.skipReason("entityOp", "ephemeral_key.$op", mode)
      Assumptions.assumeTrue(
        reason == null,
        if (reason == null || "" == reason) "skipped via sdk-test-control.json" else reason,
      )
    }
    val client = setup.client

    // CREATE
    val ephemeralKeyRef01Ent = client.ephemeralKey(null)
    var ephemeralKeyRef01Data: MutableMap<String, Any?> = (Helpers.toMapAny(Struct.getprop(
        Struct.getpath(setup.data, "new.ephemeral_key"), "ephemeral_key_ref01")) ?: linkedMapOf())

    val ephemeralKeyRef01DataResult = ephemeralKeyRef01Ent.create(ephemeralKeyRef01Data, null)
    ephemeralKeyRef01Data = Helpers.toMapAny(if (ephemeralKeyRef01DataResult is SdkEntity) ephemeralKeyRef01DataResult.data() else ephemeralKeyRef01DataResult) ?: linkedMapOf()
    assertNotNull(ephemeralKeyRef01Data, "expected create result to be a map")

  }

  private fun hasFeature(name: String): Boolean {
    val fm = Helpers.toMapAny(Config.sharedConfig()["feature"])
    return fm != null && fm[name] != null
  }

  @Test
  fun validate() {
    Assumptions.assumeTrue(hasFeature("validate"), "feature not present in this SDK: validate")
    val client = UnivecSDK.testSDK(null, linkedMapOf<String, Any?>(
      "feature" to linkedMapOf<String, Any?>(
        "validate" to linkedMapOf<String, Any?>("active" to true))))
    val err = assertThrows(SdkError::class.java) {
      client.ephemeralKey(null).create(linkedMapOf<String, Any?>("dailyLimit" to "x", "dailyUsed" to 1, "key" to "x", "resetsAt" to "x"), null)
    }
    assertEquals("validate_failed", err.code)
  }

  companion object {
    fun ephemeralKeyBasicSetup(extra: MutableMap<String, Any?>?): RunnerSupport.EntityTestSetup {
      RunnerSupport.loadEnvLocal()

      val entityData: MutableMap<String, Any?>
      try {
        val entityDataSource = Files.readString(Paths.get(
            "..", ".sdk", "test", "entity", "ephemeral_key", "EphemeralKeyTestData.json"))
        entityData = Helpers.toMapAny(Json.parse(entityDataSource)) ?: linkedMapOf()
      } catch (e: Exception) {
        throw AssertionError("failed to read ephemeral_key test data: " + e.message, e)
      }

      val options = linkedMapOf<String, Any?>()
      options["entity"] = entityData["existing"]

      var client = UnivecSDK.testSDK(options, extra)

      // Generate idmap via transform, matching TS pattern.
      val idnames = mutableListOf<Any?>()
      idnames.add("ephemeral_key01")
      idnames.add("ephemeral_key02")
      idnames.add("ephemeral_key03")
      val idmap = Struct.transform(idnames, Json.parse(
          "{\"`\$PACK`\": [\"\", {" +
          "\"`\$KEY`\": \"`\$COPY`\"," +
          "\"`\$VAL`\": [\"`\$FORMAT`\", \"upper\", \"`\$COPY`\"]" +
          "}]}"))

      // Whether *_ENTID supplied the idmap, read before envOverride consumes it.
      val entidEnvRaw = RunnerSupport.getenv("UNIVEC_TEST_EPHEMERAL_KEY_ENTID")
      val idmapOverridden = entidEnvRaw != null && entidEnvRaw.trim().startsWith("{")

      val envm = linkedMapOf<String, Any?>()
      envm["UNIVEC_TEST_EPHEMERAL_KEY_ENTID"] = idmap
      envm["UNIVEC_TEST_LIVE"] = "FALSE"
      envm["UNIVEC_TEST_EXPLAIN"] = "FALSE"
      envm["UNIVEC_APIKEY"] = "NONE"
      val env = RunnerSupport.envOverride(envm)

      var idmapResolved = Helpers.toMapAny(env["UNIVEC_TEST_EPHEMERAL_KEY_ENTID"])
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
