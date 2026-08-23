// Generated basic-flow test for the ephemeral_key entity (model-driven;
// mirrors the java TestEntity generator). A dependency-free scala-cli test
// object driven by SdkEntityTestMain. Runs against the in-memory test
// transport seeded with the shipped EphemeralKeyTestData.json fixtures.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import voxgig.univecsdk.core.{Helpers, SdkEntity, UnivecSDK}
import voxgig.univecsdk.utility.struct.Struct

object EphemeralKeyEntityTest {

  def run(rep: SdkTestReport): Unit = {
    rep.scope("ephemeral_key.instance") {
      val testsdk = UnivecSDK.testSDK()
      val ent = testsdk.ephemeralKey(null)
      rep.check("ephemeral_key.instance", ent != null, "expected non-null ephemeral_key entity")
    }

    rep.scope("ephemeral_key.basic") {
      val entityData = Helpers.toMapAny(SdkTestSupport.readJson(
          "../.sdk/test/entity/ephemeral_key/EphemeralKeyTestData.json"))
      val options = new LinkedHashMap[String, Object]()
      options.put("entity", entityData.get("existing"))
      val client = UnivecSDK.testSDK(options, null)

      val idmap = new LinkedHashMap[String, Object]()
      idmap.put("ephemeral_key01", "EPHEMERAL_KEY01")
      idmap.put("ephemeral_key02", "EPHEMERAL_KEY02")
      idmap.put("ephemeral_key03", "EPHEMERAL_KEY03")
      val now = System.currentTimeMillis()

      // CREATE
      val ephemeralKeyRef01Ent = client.ephemeralKey(null)
      var ephemeralKeyRef01Data = Helpers.toMapAny(Struct.getprop(
          Struct.getpath(entityData, "new.ephemeral_key"), "ephemeral_key_ref01"))
      val ephemeralKeyRef01DataResult = ephemeralKeyRef01Ent.create(ephemeralKeyRef01Data, null)
      ephemeralKeyRef01Data = Helpers.toMapAny(ephemeralKeyRef01DataResult match { case e: SdkEntity => e.data(); case o => o })
      rep.check("ephemeral_key.create.map", ephemeralKeyRef01Data != null, "expected create result to be a map")
    }
  }
}
