// Generated basic-flow test for the embed entity (model-driven;
// mirrors the java TestEntity generator). A dependency-free scala-cli test
// object driven by SdkEntityTestMain. Runs against the in-memory test
// transport seeded with the shipped EmbedTestData.json fixtures.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import voxgig.univecsdk.core.{Config, Context, Helpers, SdkEntity, SdkError, UnivecSDK}
import voxgig.univecsdk.feature.BaseFeature
import voxgig.univecsdk.utility.struct.Struct

object EmbedEntityTest {

  import SdkTestSupport.{B, I, jl, om}

  private def hasFeature(name: String): Boolean = {
    val fm = Helpers.toMapAny(Config.sharedConfig().get("feature"))
    fm != null && fm.get(name) != null
  }

  def run(rep: SdkTestReport): Unit = {
    rep.scope("embed.instance") {
      val testsdk = UnivecSDK.testSDK()
      val ent = testsdk.embed(null)
      rep.check("embed.instance", ent != null, "expected non-null embed entity")
    }

    rep.scope("embed.validate") {
      if (hasFeature("validate")) {
        val client = UnivecSDK.testSDK(null, om("feature" -> om("validate" -> om("active" -> B(true)))))
        val err = try {
          client.embed(null).create(om("embeddings" -> "x", "model" -> I(1), "texts" -> "x"), null)
          null
        } catch { case e: SdkError => e }
        rep.check("embed.validate", err != null && "validate_failed" == err.code,
          "expected validate_failed, got " + err)
      }
    }

    rep.scope("embed.basic") {
      val entityData = Helpers.toMapAny(SdkTestSupport.readJson(
          "../.sdk/test/entity/embed/EmbedTestData.json"))
      val options = new LinkedHashMap[String, Object]()
      options.put("entity", entityData.get("existing"))
      val client = UnivecSDK.testSDK(options, null)

      val idmap = new LinkedHashMap[String, Object]()
      idmap.put("embed01", "EMBED01")
      idmap.put("embed02", "EMBED02")
      idmap.put("embed03", "EMBED03")
      val now = System.currentTimeMillis()

      // CREATE
      val embedRef01Ent = client.embed(null)
      var embedRef01Data = Helpers.toMapAny(Struct.getprop(
          Struct.getpath(entityData, "new.embed"), "embed_ref01"))
      val embedRef01DataResult = embedRef01Ent.create(embedRef01Data, null)
      embedRef01Data = Helpers.toMapAny(embedRef01DataResult match { case e: SdkEntity => e.data(); case o => o })
      rep.check("embed.create.map", embedRef01Data != null, "expected create result to be a map")
    }
  }
}
