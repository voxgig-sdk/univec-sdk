// Generated basic-flow test for the model entity (model-driven;
// mirrors the java TestEntity generator). A dependency-free scala-cli test
// object driven by SdkEntityTestMain. Runs against the in-memory test
// transport seeded with the shipped ModelTestData.json fixtures.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import voxgig.univecsdk.core.{Helpers, SdkEntity, UnivecSDK}
import voxgig.univecsdk.utility.struct.Struct

object ModelEntityTest {

  def run(rep: SdkTestReport): Unit = {
    rep.scope("model.instance") {
      val testsdk = UnivecSDK.testSDK()
      val ent = testsdk.model(null)
      rep.check("model.instance", ent != null, "expected non-null model entity")
    }

    rep.scope("model.basic") {
      val entityData = Helpers.toMapAny(SdkTestSupport.readJson(
          "../.sdk/test/entity/model/ModelTestData.json"))
      val options = new LinkedHashMap[String, Object]()
      options.put("entity", entityData.get("existing"))
      val client = UnivecSDK.testSDK(options, null)

      val idmap = new LinkedHashMap[String, Object]()
      idmap.put("model01", "MODEL01")
      idmap.put("model02", "MODEL02")
      idmap.put("model03", "MODEL03")
      val now = System.currentTimeMillis()

      // LIST
      val modelRef01Ent = client.model(null)
      val modelRef01Match = new LinkedHashMap[String, Object]()
      val modelRef01ListResult = modelRef01Ent.list(modelRef01Match, null)
      rep.check("model.list.islist", modelRef01ListResult.isInstanceOf[JList[?]], "expected list result to be an array, got " + modelRef01ListResult)
    }
  }
}
