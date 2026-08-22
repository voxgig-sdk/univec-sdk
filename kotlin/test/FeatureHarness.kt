package voxgig.univecsdk.sdktest

// Offline feature-test harness: drives features through a faithful miniature
// of the real operation pipeline against a configurable mock transport — the
// same hook order and short-circuit rules as the generated entity op code,
// but with no live server and no API-specific fixtures.

import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.TreeMap
import java.util.function.Supplier

import voxgig.univecsdk.core.Config
import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Feature
import voxgig.univecsdk.core.FetcherFn
import voxgig.univecsdk.core.Helpers
import voxgig.univecsdk.core.Operation
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.core.Response
import voxgig.univecsdk.core.Result
import voxgig.univecsdk.core.SdkError
import voxgig.univecsdk.core.Spec
import voxgig.univecsdk.core.Utility

@Suppress("UNCHECKED_CAST")
object FeatureHarness {

  // fhHasFeature is true when this SDK was generated with the named feature.
  fun fhHasFeature(name: String): Boolean {
    val config = Config.makeConfig()
    val fm = Helpers.toMapAny(config["feature"])
    return fm != null && fm[name] != null
  }

  // FhClock is a deterministic virtual clock.
  class FhClock {
    var t: Long = 0

    fun now(): Long = t

    fun sleep(ms: Int) {
      t += ms
    }

    fun advance(ms: Int) {
      t += ms
    }
  }

  // fhResponse builds a transport-shaped response the pipeline understands.
  fun fhResponse(status: Int, data: Any?, headers: Map<String, Any?>?): MutableMap<String, Any?> {
    val h = linkedMapOf<String, Any?>()
    if (headers != null) {
      for (e in headers.entries) {
        h[e.key.lowercase()] = e.value
      }
    }
    val out = linkedMapOf<String, Any?>()
    out["status"] = status
    out["statusText"] = if (status >= 400) "ERR" else "OK"
    out["body"] = "not-used"
    out["json"] = Supplier<Any?> { data }
    out["headers"] = h
    return out
  }

  // FhRecorder is a mock transport recording every call.
  class FhRecorder {
    val calls: MutableList<MutableMap<String, Any?>> = mutableListOf()
    var reply: ((Int, MutableMap<String, Any?>) -> Any?)? = null

    fun fetch(ctx: Context, url: String, fetchdef: MutableMap<String, Any?>): Any? {
      val call = linkedMapOf<String, Any?>()
      call["url"] = url
      call["fetchdef"] = fetchdef
      calls.add(call)
      val r = reply
      if (r != null) {
        return r(calls.size, fetchdef)
      }
      val data = linkedMapOf<String, Any?>()
      data["ok"] = true
      data["n"] = calls.size
      return fhResponse(200, data, null)
    }

    fun headers(i: Int): MutableMap<String, Any?> {
      val fetchdef = Helpers.toMapAny(calls[i]["fetchdef"])
      val headers = if (fetchdef == null) null else Helpers.toMapAny(fetchdef["headers"])
      return headers ?: linkedMapOf()
    }

    fun fetchdef(i: Int): MutableMap<String, Any?> {
      val fetchdef = Helpers.toMapAny(calls[i]["fetchdef"])
      return fetchdef ?: linkedMapOf()
    }

    fun url(i: Int): String {
      val url = calls[i]["url"]
      return if (url is String) url else ""
    }
  }

  // FhFeature pairs a feature instance with its init options.
  class FhFeature(val f: Feature, val options: MutableMap<String, Any?>?)

  fun fhF(f: Feature, options: MutableMap<String, Any?>?): FhFeature {
    return FhFeature(f, options)
  }

  class FhOpSpec {
    var entityVal = ""
    var opVal = ""
    var methodVal = ""
    var pathVal = ""
    var queryVal: MutableMap<String, Any?>? = null
    var headersVal: MutableMap<String, Any?>? = null
    var bodyVal: Any? = null
    var ctrlVal: MutableMap<String, Any?>? = null

    fun op(v: String): FhOpSpec = apply { opVal = v }
    fun entity(v: String): FhOpSpec = apply { entityVal = v }
    fun method(v: String): FhOpSpec = apply { methodVal = v }
    fun path(v: String): FhOpSpec = apply { pathVal = v }
    fun query(v: MutableMap<String, Any?>): FhOpSpec = apply { queryVal = v }
    fun headers(v: MutableMap<String, Any?>): FhOpSpec = apply { headersVal = v }
    fun body(v: Any?): FhOpSpec = apply { bodyVal = v }
    fun ctrl(v: MutableMap<String, Any?>): FhOpSpec = apply { ctrlVal = v }
  }

  fun fhOp(op: String): FhOpSpec = FhOpSpec().op(op)

  class FhOpResult {
    var ok: Boolean = false
    var data: Any? = null
    var err: RuntimeException? = null
    var result: Result? = null
    var ctx: Context? = null
  }

  fun fhDefaultMethod(op: String): String {
    return when (op) {
      "create" -> "POST"
      "update" -> "PATCH"
      "remove" -> "DELETE"
      else -> "GET"
    }
  }

  fun fhBuildUrl(spec: Spec): String {
    val keys = mutableListOf<String>()
    for (e in TreeMap(spec.query).entries) {
      if (e.value != null) {
        keys.add(e.key)
      }
    }
    val qs = StringBuilder()
    for (k in keys) {
      if (qs.isNotEmpty()) {
        qs.append("&")
      }
      qs.append(URLEncoder.encode(k, StandardCharsets.UTF_8))
        .append("=")
        .append(URLEncoder.encode(spec.query[k].toString(), StandardCharsets.UTF_8))
    }
    var url = spec.base + spec.path
    if (qs.isNotEmpty()) {
      url += "?$qs"
    }
    return url
  }

  // FhHarness wires features (in init order) to a mock transport and a mini
  // operation pipeline.
  class FhHarness {
    lateinit var client: UnivecSDK
    lateinit var utility: Utility
    lateinit var rootctx: Context
    var base = "http://api.test"

    fun op(o: FhOpSpec): FhOpResult {
      val entity = if ("" == o.entityVal) "widget" else o.entityVal
      val opname = if ("" == o.opVal) "load" else o.opVal
      val method = if ("" == o.methodVal) fhDefaultMethod(opname) else o.methodVal
      val ctrl = o.ctrlVal ?: linkedMapOf()

      val ctxmap = linkedMapOf<String, Any?>()
      ctxmap["opname"] = opname
      ctxmap["ctrl"] = ctrl
      val ctx = utility.makeContext(ctxmap, rootctx)
      val opdef = linkedMapOf<String, Any?>()
      opdef["entity"] = entity
      opdef["name"] = opname
      ctx.op = Operation(opdef)

      utility.featureHook(ctx, "PostConstructEntity")

      utility.featureHook(ctx, "PrePoint")
      val outPoint = ctx.out["point"]
      if (outPoint is RuntimeException) {
        return fail(ctx, outPoint)
      }

      utility.featureHook(ctx, "PreSpec")
      val path = if ("" == o.pathVal) "/$entity" else o.pathVal
      val headers = linkedMapOf<String, Any?>()
      if (o.headersVal != null) {
        headers.putAll(o.headersVal!!)
      }
      val query = linkedMapOf<String, Any?>()
      if (o.queryVal != null) {
        query.putAll(o.queryVal!!)
      }
      val specmap = linkedMapOf<String, Any?>()
      specmap["method"] = method
      specmap["base"] = base
      specmap["path"] = path
      specmap["headers"] = headers
      specmap["query"] = query
      specmap["step"] = "start"
      ctx.spec = Spec(specmap)
      if (o.bodyVal != null) {
        ctx.spec!!.body = o.bodyVal
      }

      utility.featureHook(ctx, "PreRequest")
      ctx.spec!!.url = fhBuildUrl(ctx.spec!!)

      val fetchdef = linkedMapOf<String, Any?>()
      fetchdef["url"] = ctx.spec!!.url
      fetchdef["method"] = ctx.spec!!.method
      fetchdef["headers"] = ctx.spec!!.headers
      if (ctx.spec!!.body != null) {
        fetchdef["body"] = ctx.spec!!.body
      }

      var response: Any? = null
      var fetchErr: RuntimeException? = null
      val outRequest = ctx.out["request"]
      if (outRequest != null) {
        response = outRequest
      } else {
        try {
          response = utility.fetcher(ctx, ctx.spec!!.url, fetchdef)
        } catch (e: RuntimeException) {
          fetchErr = e
        }
      }
      if (response is MutableMap<*, *>) {
        ctx.response = Response(response as MutableMap<String, Any?>)
      }

      utility.featureHook(ctx, "PreResponse")
      fhPopulateResult(ctx, response, fetchErr)
      utility.featureHook(ctx, "PreResult")
      utility.featureHook(ctx, "PreDone")

      val result = ctx.result
      if (result != null && result.ok) {
        val out = FhOpResult()
        out.ok = true
        out.data = result.resdata
        out.result = result
        out.ctx = ctx
        return out
      }

      val err: RuntimeException = if (result != null && result.err != null) {
        result.err!!
      } else {
        ctx.makeError("op_failed", "operation failed")
      }
      return fail(ctx, err)
    }

    fun fail(ctx: Context, err: RuntimeException): FhOpResult {
      ctx.ctrl.err = err
      utility.featureHook(ctx, "PreUnexpected")
      val out = FhOpResult()
      out.ok = false
      out.err = err
      out.result = ctx.result
      out.ctx = ctx
      return out
    }
  }

  // fhMake constructs the harness.
  fun fhMake(server: FetcherFn?, vararg features: FhFeature): FhHarness {
    val client = UnivecSDK.testSDK()
    client.features = mutableListOf()

    val utility = client.getUtility()
    var srv = server
    if (srv == null) {
      val rec = FhRecorder()
      srv = rec::fetch
    }
    utility.fetcher = srv

    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["client"] = client
    ctxmap["utility"] = utility
    val rootctx = utility.makeContext(ctxmap, client.getRootCtx())

    for (fs in features) {
      val fopts = linkedMapOf<String, Any?>()
      fopts["active"] = true
      if (fs.options != null) {
        fopts.putAll(fs.options)
      }
      fs.f.init(rootctx, fopts)
      client.features.add(fs.f)
    }

    utility.featureHook(rootctx, "PostConstruct")

    val h = FhHarness()
    h.client = client
    h.utility = utility
    h.rootctx = rootctx
    return h
  }

  fun fhPopulateResult(ctx: Context, response: Any?, fetchErr: RuntimeException?) {
    val result = Result(linkedMapOf())
    ctx.result = result

    if (fetchErr != null) {
      result.err = fetchErr
      return
    }

    if (response !is MutableMap<*, *>) {
      result.err = ctx.makeError("request_no_response", "response: undefined")
      return
    }

    val resp = Response(response as MutableMap<String, Any?>)
    result.status = resp.status
    result.statusText = resp.statusText
    val hm = Helpers.toMapAny(resp.headers)
    if (hm != null) {
      result.headers = hm
    }
    if (resp.jsonFunc != null) {
      result.body = resp.jsonFunc!!.get()
    }
    result.resdata = result.body

    if (result.status >= 400) {
      result.err = ctx.makeError("request_status", "request: " + result.status + ": " + result.statusText)
    } else if (resp.err != null) {
      result.err = resp.err
    }
    if (result.err == null) {
      result.ok = true
    }
  }

  // fhErrCode extracts the SDK error code, "" otherwise.
  fun fhErrCode(err: RuntimeException?): String {
    if (err is SdkError) {
      return err.code
    }
    return ""
  }

  // Small map builder for test options.
  fun fhMap(vararg kv: Any?): MutableMap<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    var i = 0
    while (i < kv.size - 1) {
      out[kv[i].toString()] = kv[i + 1]
      i += 2
    }
    return out
  }
}
