package voxgig.univecsdk.sdktest

// Shared test-runner support: env overrides, sdk-test-control.json skips, the
// ../.sdk/test/test.json spec loader, and the runset/match engine whose
// matching logic mirrors js/test/runner.js (and the go runner_test.go).

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
import voxgig.univecsdk.utility.struct.Struct

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

  fun interface RunSubject {
    fun run(entry: MutableMap<String, Any?>): Any?
  }

  // runset drives a test.json entry set against a subject.
  fun runset(testspec: Map<String, Any?>?, subject: RunSubject) {
    if (testspec == null || testspec["set"] !is List<*>) {
      return
    }
    val set = testspec["set"] as List<Any?>

    val failures = mutableListOf<String>()

    for (i in set.indices) {
      val entry = Helpers.toMapAny(set[i]) ?: continue

      val mark = if (entry["mark"] == null) "" else " (mark=" + entry["mark"] + ")"

      var result: Any? = null
      var err: Exception? = null
      try {
        result = subject.run(entry)
      } catch (e: Exception) {
        err = e
      }

      val expectedErr = entry["err"]

      if (err != null) {
        if (expectedErr != null) {
          val errMsg = err.message ?: err.toString()
          if (expectedErr is String && !matchString(expectedErr, errMsg)) {
            failures.add("entry $i$mark: error mismatch: got \"$errMsg\", want contains \"$expectedErr\"")
          }
          val matchSpec = Helpers.toMapAny(entry["match"])
          if (matchSpec != null) {
            val resultMap = linkedMapOf<String, Any?>()
            resultMap["in"] = entry["in"]
            resultMap["out"] = jsonNormalize(result)
            val errRec = linkedMapOf<String, Any?>()
            errRec["message"] = errMsg
            resultMap["err"] = errRec
            matchDeep(failures, i, mark, matchSpec, resultMap, "")
          }
          continue
        }
        failures.add("entry $i$mark: unexpected error: $err")
        continue
      }

      if (expectedErr != null) {
        failures.add("entry $i$mark: expected error containing \"$expectedErr\" but got result: ${jsonStr(result)}")
        continue
      }

      var matched = false
      val matchSpec = Helpers.toMapAny(entry["match"])
      if (matchSpec != null) {
        val resultMap = linkedMapOf<String, Any?>()
        resultMap["in"] = entry["in"]
        resultMap["out"] = jsonNormalize(result)
        if (entry["args"] != null) {
          resultMap["args"] = entry["args"]
        } else if (entry["in"] != null) {
          val args = mutableListOf<Any?>()
          args.add(entry["in"])
          resultMap["args"] = args
        }
        if (entry["ctx"] != null) {
          resultMap["ctx"] = entry["ctx"]
        }
        matchDeep(failures, i, mark, matchSpec, resultMap, "")
        matched = true
      }

      val expectedOut = entry["out"]
      if (expectedOut == null && matched) {
        continue
      }
      if (expectedOut != null) {
        val normResult = jsonNormalize(result)
        val normExpected = jsonNormalize(expectedOut)
        if (canon(normResult) != canon(normExpected)) {
          failures.add("entry $i$mark: output mismatch:\n  got:  ${jsonStr(normResult)}\n  want: ${jsonStr(normExpected)}")
        }
      }
    }

    if (failures.isNotEmpty()) {
      throw AssertionError(failures.joinToString("\n"))
    }
  }

  fun jsonNormalize(v: Any?): Any? {
    if (v == null) {
      return null
    }
    return try {
      Json.parse(Struct.jsonify(v))
    } catch (e: RuntimeException) {
      v
    }
  }

  fun jsonStr(v: Any?): String {
    return try {
      Struct.jsonify(v)
    } catch (e: RuntimeException) {
      v.toString()
    }
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

  fun matchDeep(failures: MutableList<String>, entryIdx: Int, mark: String, check: Any?, base: Any?, path: String) {
    if (check == null) {
      return
    }

    if (check is Map<*, *>) {
      for (e in (check as Map<String, Any?>).entries) {
        val childPath = "$path.${e.key}"
        val baseVal = if (base is Map<*, *>) (base as Map<String, Any?>)[e.key] else null
        matchDeep(failures, entryIdx, mark, e.value, baseVal, childPath)
      }
    } else if (check is List<*>) {
      for (i in check.indices) {
        val childPath = "$path[$i]"
        var baseVal: Any? = null
        if (base is List<*> && i < base.size) {
          baseVal = base[i]
        }
        matchDeep(failures, entryIdx, mark, check[i], baseVal, childPath)
      }
    } else {
      if ("__EXISTS__" == check) {
        if (base == null) {
          failures.add("entry $entryIdx$mark: match $path: expected value to exist but got null")
        }
        return
      }
      if ("__UNDEF__" == check) {
        if (base != null) {
          failures.add("entry $entryIdx$mark: match $path: expected null but got $base")
        }
        return
      }

      val normCheck = jsonNormalize(check)
      val normBase = jsonNormalize(base)

      if (canon(normCheck) != canon(normBase)) {
        if (check is String && "" != check) {
          val baseStr = Struct.stringify(base)
          if (matchString(check, baseStr)) {
            return
          }
        }
        failures.add("entry $entryIdx$mark: match $path: got ${jsonStr(normBase)}, want ${jsonStr(normCheck)}")
      }
    }
  }

  // matchString checks if val matches pattern. If pattern is /regex/, use
  // regex; otherwise do case-insensitive contains.
  fun matchString(pattern: String, v: String): Boolean {
    if (pattern.length >= 2 && pattern.startsWith("/") && pattern.endsWith("/")) {
      return try {
        Regex(pattern.substring(1, pattern.length - 1)).containsMatchIn(v)
      } catch (e: RuntimeException) {
        false
      }
    }
    return v.lowercase().contains(pattern.lowercase())
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
