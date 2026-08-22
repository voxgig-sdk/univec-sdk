// Generated basic-flow test for the convert entity (model-driven;
// mirrors the java TestEntity generator). A dependency-free scala-cli test
// object driven by SdkEntityTestMain. Runs against the in-memory test
// transport seeded with the shipped ConvertTestData.json fixtures.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import voxgig.univecsdk.core.{Helpers, UnivecSDK}
import voxgig.univecsdk.utility.struct.Struct

object ConvertEntityTest {

  def run(rep: SdkTestReport): Unit = {
    rep.scope("convert.instance") {
      val testsdk = UnivecSDK.testSDK()
      val ent = testsdk.convert(null)
      rep.check("convert.instance", ent != null, "expected non-null convert entity")
    }

    rep.scope("convert.basic") {
      val entityData = Helpers.toMapAny(SdkTestSupport.readJson(
          "../.sdk/test/entity/convert/ConvertTestData.json"))
      val options = new LinkedHashMap[String, Object]()
      options.put("entity", entityData.get("existing"))
      val client = UnivecSDK.testSDK(options, null)

      val idmap = new LinkedHashMap[String, Object]()
      idmap.put("convert01", "CONVERT01")
      idmap.put("convert02", "CONVERT02")
      idmap.put("convert03", "CONVERT03")
      val now = System.currentTimeMillis()

      // CREATE
      val convertRef01Ent = client.convert(null)
      var convertRef01Data = Helpers.toMapAny(Struct.getprop(
          Struct.getpath(entityData, "new.convert"), "convert_ref01"))
      val convertRef01DataResult = convertRef01Ent.create(convertRef01Data, null)
      convertRef01Data = Helpers.toMapAny(convertRef01DataResult match { case e: SdkEntity => e.data(); case o => o })
      rep.check("convert.create.map", convertRef01Data != null, "expected create result to be a map")
    }
  }
}
