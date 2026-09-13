package voxgig.univecsdk.sdktest

// Shared test-runner SUPPORT (vendor-tag rollout): env overrides, the
// sdk-test-control.json skip machinery, live pacing, the
// ../.sdk/test/test.json spec loader, ctx/entity conversion helpers, and
// the canon comparison helper the feature tests use. The corpus ENGINE
// that used to live beside them (runset/matchDeep/matchString) is
// retired: both corpora now run on the vendored omni runner through
// OmniResolver.kt. The object name is unchanged so the emitted
// TestEntity/TestDirect call sites (RunnerSupport.skipReason,
// RunnerSupport.envOverride, ...) need no churn.

import java.nio.file.Files
import java.nio.file.Paths
import java.util.TreeMap
import java.util.function.Supplier

import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Entity
import voxgig.univecsdk.core.Helpers
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.core.Response
import voxgig.univecsdk.core.Result
import voxgig.univecsdk.core.SdkError
import voxgig.univecsdk.core.Spec
import voxgig.univecsdk.core.Utility
import voxgig.univecsdk.utility.Json

@Suppress("UNCHECKED_CAST")
object RunnerSupport {

  private var envLocalLoaded = false
  private val envLocal = linkedMapOf<String, String>()

  private var cachedTestControl: Map<String, Any?>? = null
  private var cachedTestSpec: Map<String, Any?>? = null

  // loadEnvLocal reads ../.env.local (if present) into an overlay map.
  @Synchronized
  fun loadEnvLocal() {
    if (envLocalLoaded) {
      return
    }
    envLocalLoaded = true
    try {
      val data = Files.readString(Paths.get("..", ".env.local"))
      for (lineRaw in data.split("\n")) {
        val line = lineRaw.trim()
        if (line.isEmpty() || line.startsWith("#")) {
          continue
        }
        val eq = line.indexOf('=')
        if (eq > 0) {
          envLocal[line.substring(0, eq).trim()] = line.substring(eq + 1).trim()
        }
      }
    } catch (e: Exception) {
      // absent .env.local is fine
    }
  }

  fun getenv(key: String): String? {
    val v = System.getenv(key)
    if (v != null && v.isNotEmpty()) {
      return v
    }
    return envLocal[key]
  }

  fun envOverride(m: MutableMap<String, Any?>): MutableMap<String, Any?> {
    if ("TRUE" == getenv("UNIVEC_TEST_LIVE") || "TRUE" == getenv("UNIVEC_TEST_OVERRIDE")) {
      for (key in ArrayList(m.keys)) {
        var envval = getenv(key)
        if (envval != null && envval.isNotEmpty()) {
          envval = envval.trim()
          if (envval.startsWith("{")) {
            val parsed = Json.parseOrNull(envval)
            if (parsed != null) {
              m[key] = parsed
              continue
            }
          }
          m[key] = envval
        }
      }
    }

    val explain = getenv("UNIVEC_TEST_EXPLAIN")
    if (explain != null && explain.isNotEmpty()) {
      m["UNIVEC_TEST_EXPLAIN"] = explain
    }

    return m
  }

  class EntityTestSetup {
    lateinit var client: UnivecSDK
    var data: MutableMap<String, Any?>? = null
    var idmap: MutableMap<String, Any?>? = null
    var env: MutableMap<String, Any?>? = null
    var explain: Boolean = false
    var live: Boolean = false
    var syntheticOnly: Boolean = false
    var now: Long = 0
  }

  @Synchronized
  fun loadTestControl(): Map<String, Any?> {
    val cached = cachedTestControl
    if (cached != null) {
      return cached
    }
    val def = Json.parse(
      "{\"version\":1,\"test\":{\"skip\":{" +
        "\"live\":{\"direct\":[],\"entityOp\":[]}," +
        "\"unit\":{\"direct\":[],\"entityOp\":[]}}}}",
    ) as Map<String, Any?>
    val result = try {
      val data = Files.readString(Paths.get("test", "sdk-test-control.json"))
      val parsed = Json.parseOrNull(data)
      if (parsed is Map<*, *>) parsed as Map<String, Any?> else def
    } catch (e: Exception) {
      def
    }
    cachedTestControl = result
    return result
  }

  // skipReason checks sdk-test-control.json for a skip entry. Returns the
  // reason ("" when none given) or null when not skipped.
  fun skipReason(kind: String, name: String, mode: String): String? {
    val ctrl = loadTestControl()
    val test = Helpers.toMapAny(ctrl["test"]) ?: return null
    val skip = Helpers.toMapAny(test["skip"]) ?: return null
    val modeMap = Helpers.toMapAny(skip[mode]) ?: return null
    val itemsRaw = modeMap[kind]
    if (itemsRaw !is List<*>) {
      return null
    }
    for (raw in itemsRaw) {
      val item = Helpers.toMapAny(raw) ?: continue
      val reason = if (item["reason"] is String) item["reason"] as String else ""
      if ("direct" == kind && name == item["test"]) {
        return reason
      }
      if ("entityOp" == kind) {
        val ent = item["entity"]
        val op = item["op"]
        if (name == "$ent.$op") {
          return reason
        }
      }
    }
    return null
  }

  fun liveDelayMs(): Int {
    val ctrl = loadTestControl()
    val test = Helpers.toMapAny(ctrl["test"]) ?: return 500
    val live = Helpers.toMapAny(test["live"]) ?: return 500
    val v = live["delayMs"]
    if (v is Number && v.toInt() >= 0) {
      return v.toInt()
    }
    return 500
  }

  @Synchronized
  fun loadTestSpec(): Map<String, Any?> {
    val cached = cachedTestSpec
    if (cached != null) {
      return cached
    }
    val result = try {
      val data = Files.readString(Paths.get("..", ".sdk", "test", "test.json"))
      Json.parse(data) as Map<String, Any?>
    } catch (e: Exception) {
      throw AssertionError("Failed to load test.json: " + e.message, e)
    }
    cachedTestSpec = result
    return result
  }

  fun getSpec(spec: Map<String, Any?>?, vararg keys: String): MutableMap<String, Any?>? {
    var cur: Any? = spec
    for (key in keys) {
      cur = if (cur is Map<*, *>) (cur as Map<String, Any?>)[key] else return null
    }
    return Helpers.toMapAny(cur)
  }

  fun canon(v: Any?): Any? {
    if (v == null) {
      return null
    }
    if (v is Number) {
      val d = v.toDouble()
      if (d.isFinite() && Math.floor(d) == d) {
        return d.toLong()
      }
      return d
    }
    if (v is Boolean || v is String) {
      return v
    }
    if (v is Map<*, *>) {
      val out = TreeMap<String, Any?>()
      for (e in v.entries) {
        out[e.key?.toString() ?: ""] = canon(e.value)
      }
      return out
    }
    if (v is List<*>) {
      val out = mutableListOf<Any?>()
      for (x in v) {
        out.add(canon(x))
      }
      return out
    }
    return v.toString()
  }

  // makeCtxFromMap creates a Context from a JSON test entry's ctx or args map.
  fun makeCtxFromMap(ctxmapIn: MutableMap<String, Any?>?, client: UnivecSDK?, utility: Utility?): Context {
    val ctxmap = ctxmapIn ?: linkedMapOf()

    val ctx = Context(ctxmap, null)

    if (client != null) {
      ctx.client = client
      ctx.utility = utility
    }
    if (ctx.options == null && client != null) {
      ctx.options = client.optionsMap()
    }

    val specMap = Helpers.toMapAny(ctxmap["spec"])
    if (specMap != null) {
      ctx.spec = Spec(specMap)
    }

    val resMap = Helpers.toMapAny(ctxmap["result"])
    if (resMap != null) {
      ctx.result = Result(resMap)
      val errMap = Helpers.toMapAny(resMap["err"])
      if (errMap != null && errMap["message"] is String) {
        ctx.result!!.err = SdkError("", errMap["message"] as String, null)
      }
    }

    val respMap = Helpers.toMapAny(ctxmap["response"])
    if (respMap != null) {
      ctx.response = Response(respMap)
      val body = respMap["body"]
      if (body != null) {
        ctx.response!!.jsonFunc = Supplier { body }
      }
      val headers = Helpers.toMapAny(respMap["headers"])
      if (headers != null) {
        val lowerHeaders = linkedMapOf<String, Any?>()
        for (h in headers.entries) {
          lowerHeaders[h.key.lowercase()] = h.value
        }
        ctx.response!!.headers = lowerHeaders
      }
    }

    return ctx
  }

  fun fixctx(ctx: Context?, client: UnivecSDK?) {
    if (ctx != null && ctx.client != null && ctx.options == null) {
      ctx.options = ctx.client!!.optionsMap()
    }
  }

  // errFromMap creates an error from a JSON map {"message": "...", "code": "..."}
  fun errFromMap(m: MutableMap<String, Any?>?): RuntimeException? {
    if (m == null) {
      return null
    }
    val msg = if (m["message"] is String) m["message"] as String else ""
    if ("" == msg) {
      return null
    }
    val code = if (m["code"] is String) m["code"] as String else ""
    return SdkError(code, msg, null)
  }

  // entityListToData extracts data maps from a list of Entity objects.
  fun entityListToData(list: List<Any?>?): MutableList<Any?> {
    val out = mutableListOf<Any?>()
    if (list == null) {
      return out
    }
    for (item in list) {
      if (item is Entity) {
        val dm = Helpers.toMapAny(item.data())
        if (dm != null) {
          out.add(dm)
        }
      } else if (item is Map<*, *>) {
        out.add(item)
      }
    }
    return out
  }
}
