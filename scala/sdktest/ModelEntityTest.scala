// Generated basic-flow test for the model entity (model-driven;
// mirrors the java TestEntity generator). A dependency-free scala-cli test
// object driven by SdkEntityTestMain. Runs against the in-memory test
// transport seeded with the shipped ModelTestData.json fixtures.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import voxgig.univecsdk.core.{Config, Context, Helpers, SdkEntity, SdkError, UnivecSDK}
import voxgig.univecsdk.feature.BaseFeature
import voxgig.univecsdk.utility.struct.Struct

object ModelEntityTest {

  import SdkTestSupport.{B, I, jl, om}

  private def hasFeature(name: String): Boolean = {
    val fm = Helpers.toMapAny(Config.sharedConfig().get("feature"))
    fm != null && fm.get(name) != null
  }

  final class FailHook extends BaseFeature("failhook", "0.0.1", true) {
    var unexpected = 0
    override def preSpec(ctx: Context): Unit = throw new RuntimeException("model hook failed")
    override def preUnexpected(ctx: Context): Unit = unexpected += 1
  }

  def run(rep: SdkTestReport): Unit = {
    rep.scope("model.instance") {
      val testsdk = UnivecSDK.testSDK()
      val ent = testsdk.model(null)
      rep.check("model.instance", ent != null, "expected non-null model entity")
    }

    rep.scope("model.stream.error") {
      val offline = om("net" -> om("offline" -> B(true)))
      val err = try {
        UnivecSDK.testSDK(offline, null).model(null).stream("list", null, null).toList
        null
      } catch { case e: RuntimeException => e }
      rep.check("model.stream.error", err != null && String.valueOf(err.getMessage).contains("offline"),
        "expected the transport failure to raise from the stream, got " + err)

      UnivecSDK.testSDK(offline, null).model(null)
        .stream("list", null, om("ctrl" -> om("throw" -> B(false)))).toList

      if (hasFeature("rbac")) {
        val denied = UnivecSDK.testSDK(null,
          om("feature" -> om("rbac" -> om("active" -> B(true), "deny" -> B(true)))))
        val denyerr = try {
          denied.model(null).stream("list", null, null).toList
          null
        } catch { case e: SdkError => e }
        rep.check("model.stream.denied", denyerr != null && "rbac_denied" == denyerr.code,
          "expected the rbac denial to raise from the stream, got " + denyerr)
      }
    }

    rep.scope("model.stream.ctrl") {
      val explain = new LinkedHashMap[String, Object]()
      val ctrl = om("explain" -> explain)
      UnivecSDK.testSDK().model(null).stream("list", null, om("ctrl" -> ctrl)).toList
      rep.check("model.stream.ctrl", 1 == ctrl.size() && (explain eq ctrl.get("explain")),
        "the stream changed the caller's ctrl")
      rep.check("model.stream.explain", !explain.isEmpty(), "the caller's explain record was not filled")
    }

    rep.scope("model.unexpected") {
      val hook = new FailHook()
      val client = new UnivecSDK(om("feature" -> om("test" -> om("active" -> B(true))), "extend" -> jl(hook)))
      val err = try {
        client.model(null).list(null, null)
        null
      } catch { case e: RuntimeException => e }
      rep.check("model.unexpected.raise", err != null && String.valueOf(err.getMessage).contains("hook failed"),
        "expected the hook's failure, got " + err)
      rep.check("model.unexpected.fired", hook.unexpected > 0, "PreUnexpected did not fire")

      val fired = hook.unexpected
      client.model(null).list(null, om("throw" -> B(false)))
      rep.check("model.unexpected.nothrow", hook.unexpected > fired,
        "PreUnexpected did not fire under throw false")
    }

    rep.scope("model.validate") {
      if (hasFeature("validate")) {
        val client = UnivecSDK.testSDK(null, om("feature" -> om("validate" -> om("active" -> B(true)))))
        val err = try {
          client.model(null).list(om("executionProvider" -> I(1)), null)
          null
        } catch { case e: SdkError => e }
        rep.check("model.validate", err != null && "validate_failed" == err.code,
          "expected validate_failed, got " + err)
      }
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
