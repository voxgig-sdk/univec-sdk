package KOTLINPACKAGE.core

import java.util.function.Supplier

import KOTLINPACKAGE.utility.struct.Struct

/**
 * Shared client runtime for the Univec SDK. The generated
 * UnivecSDK class extends this with the API-specific entity accessors;
 * everything transport- and pipeline-related lives here so features and
 * utilities can reference a fixed type.
 */
@Suppress("UNCHECKED_CAST")
abstract class SdkClient(sdkopts: MutableMap<String, Any?>?) {

  var mode: String = "live"
  var features: MutableList<Feature> = mutableListOf()

  protected val util: Utility = Utility()
  protected var options: MutableMap<String, Any?> = linkedMapOf()
  protected val rootctx: Context

  init {
    // The process-wide config (sdkgen rung L2): read-only on the request path,
    // so every client shares one rather than rebuilding it.
    val config = Config.sharedConfig()

    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["client"] = this
    ctxmap["utility"] = this.util
    ctxmap["config"] = config
    if (sdkopts != null) {
      ctxmap["options"] = sdkopts
    }
    ctxmap["shared"] = linkedMapOf<String, Any?>()

    this.rootctx = this.util.makeContext(ctxmap, null)

    this.options = this.util.makeOptions(this.rootctx)

    if (Struct.getpath(this.options, listOf("feature", "test", "active")) == true) {
      this.mode = "test"
    }

    this.rootctx.options = this.options

    // Add features in the resolved order (makeOptions puts an explicit list
    // order first, else defaults to test-first). Ordering matters: the `test`
    // feature installs the base mock transport and the transport features
    // (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
    // must be added before them to sit at the base of the chain.
    val featureOpts = Helpers.toMapAny(Struct.getprop(this.options, "feature"))
      ?: linkedMapOf()
    val featureOrder = Struct.getpath(this.options, listOf("__derived__", "featureorder"))
    if (featureOrder is List<*>) {
      for (fnameObj in featureOrder) {
        val fname = fnameObj as? String
        val fopts = Helpers.toMapAny(Struct.getprop(featureOpts, fname))
        if (fname != null && fopts != null && fopts["active"] == true) {
          val f = Config.makeFeature(fname)
          this.util.featureAdd(this.rootctx, f)
        }
      }
    }

    // Add extension features.
    val extend = Struct.getprop(this.options, "extend")
    if (extend is List<*>) {
      for (f in extend) {
        if (f is Feature) {
          this.util.featureAdd(this.rootctx, f)
        }
      }
    }

    // Initialize features.
    for (f in ArrayList(this.features)) {
      this.util.featureInit(this.rootctx, f)
    }

    this.util.featureHook(this.rootctx, "PostConstruct")
  }

  fun optionsMap(): MutableMap<String, Any?> {
    val out = Struct.clone(this.options)
    if (out is MutableMap<*, *>) {
      return out as MutableMap<String, Any?>
    }
    return linkedMapOf()
  }

  fun getUtility(): Utility {
    return this.util.copy()
  }

  fun getRootCtx(): Context {
    return this.rootctx
  }

  fun prepare(fetchargsIn: MutableMap<String, Any?>?): MutableMap<String, Any?> {
    val utility = this.util

    val fetchargs = fetchargsIn ?: linkedMapOf()

    var ctrl = Helpers.toMapAny(Struct.getprop(fetchargs, "ctrl"))
    if (ctrl == null) {
      ctrl = linkedMapOf()
    }

    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "prepare"
    ctxmap["ctrl"] = ctrl
    val ctx = utility.makeContext(ctxmap, this.rootctx)

    val options = this.options

    val pathRaw = Struct.getprop(fetchargs, "path")
    val path = if (pathRaw is String) pathRaw else ""
    val methodRaw = Struct.getprop(fetchargs, "method")
    var method = if (methodRaw is String) methodRaw else ""
    if ("" == method) {
      method = "GET"
    }

    var params = Helpers.toMapAny(Struct.getprop(fetchargs, "params"))
    if (params == null) {
      params = linkedMapOf()
    }
    var query = Helpers.toMapAny(Struct.getprop(fetchargs, "query"))
    if (query == null) {
      query = linkedMapOf()
    }

    val headers = utility.prepareHeaders(ctx)

    val base = Struct.getprop(options, "base")
    val prefix = Struct.getprop(options, "prefix")
    val suffix = Struct.getprop(options, "suffix")

    val specmap = linkedMapOf<String, Any?>()
    specmap["base"] = if (base is String) base else ""
    specmap["prefix"] = if (prefix is String) prefix else ""
    specmap["suffix"] = if (suffix is String) suffix else ""
    specmap["path"] = path
    specmap["method"] = method
    specmap["params"] = params
    specmap["query"] = query
    specmap["headers"] = headers
    specmap["body"] = Struct.getprop(fetchargs, "body", null)
    specmap["step"] = "start"
    ctx.spec = Spec(specmap)

    // Merge user-provided headers.
    val uheaders = Helpers.toMapAny(Struct.getprop(fetchargs, "headers"))
    if (uheaders != null) {
      ctx.spec!!.headers.putAll(uheaders)
    }

    utility.prepareAuth(ctx)

    return utility.makeFetchDef(ctx)
  }

  // Raw endpoint access is operator-controllable, like every entity op.
  // Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
  // either one reaches the same endpoint.
  fun direct(fetchargsIn: MutableMap<String, Any?>?): MutableMap<String, Any?> {
    if (!opAllowed("direct")) {
      return opDenied("direct")
    }

    return rawRequest(fetchargsIn)
  }

  // Is this raw-access op permitted by the SDK's allow.op option?
  private fun opAllowed(op: String): Boolean {
    val allow = Struct.getpath(this.options, listOf("allow", "op"))
    return allow is String && allow.contains(op)
  }

  private fun opDenied(op: String): MutableMap<String, Any?> {
    val allow = Struct.getpath(this.options, listOf("allow", "op")) as? String
    val out = linkedMapOf<String, Any?>()
    out["ok"] = false
    out["err"] = SdkError(op + "_allow",
      "UnivecSDK: " + op + ": operation not allowed by" +
        " SDK option allow.op value: \"" + (allow ?: "") + "\"", null)
    return out
  }

  // Raw GraphQL access: the pressure valve that makes the generated
  // surface's deliberate omissions (per-call selection sets, typed filter
  // builders, batching, subscriptions) livable — the whole schema stays
  // reachable.
  //
  // Thin wrapper over the same prepare/fetch path direct uses, with the one
  // thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200
  // as a top-level `errors` array, so status alone would report a failed
  // query as ok.
  //
  // NOTE: like direct, this bypasses the feature pipeline — no retry,
  // ratelimit or paging features apply.
  @JvmOverloads
  fun graphql(
    query: String,
    variables: MutableMap<String, Any?>? = null,
    ctrl: MutableMap<String, Any?>? = null,
  ): MutableMap<String, Any?> {
    if (!opAllowed("graphql")) {
      return opDenied("graphql")
    }

    val res = rawRequest(linkedMapOf<String, Any?>(
      "method" to "POST",
      "headers" to linkedMapOf<String, Any?>(
        "content-type" to "application/json"),
      "body" to linkedMapOf<String, Any?>(
        "query" to query,
        "variables" to (variables ?: linkedMapOf<String, Any?>())),
      "ctrl" to (ctrl ?: linkedMapOf<String, Any?>()),
    ))

    // Errors are read BEFORE any status check: a GraphQL parse or validation
    // failure comes back as HTTP 400 carrying the standard { errors: [...] }
    // body, and the raw path represents a non-2xx as ok:false with no err —
    // so returning early on status would discard the server's own
    // diagnostics, which are the only useful part of that response.
    val errors = Struct.getpath(res, listOf("data", "errors")) as? List<Any?>

    if (null != errors && errors.isNotEmpty()) {
      val m = Struct.getprop(errors[0], "message") as? String
      val msg = if (m.isNullOrEmpty()) "graphql error" else m
      res["ok"] = false
      res["err"] = SdkError("graphql_error",
        "UnivecSDK: graphql: " + msg, null)
      res["graphql"] = errors
    }

    return res
  }

  // Ungated request path shared by direct and graphql, each of which checks
  // its own allow.op token first. Private, rather than a flag on fetchargs: a
  // caller-supplied marker would let anyone opt straight back out of the gate
  // by passing it.
  private fun rawRequest(
    fetchargsIn: MutableMap<String, Any?>?,
  ): MutableMap<String, Any?> {
    val utility = this.util

    val fetchargs = fetchargsIn ?: linkedMapOf()

    var ctrl = Helpers.toMapAny(Struct.getprop(fetchargs, "ctrl"))
    if (ctrl == null) {
      ctrl = linkedMapOf()
    }

    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "direct"
    ctxmap["ctrl"] = ctrl
    val ctx = utility.makeContext(ctxmap, this.rootctx)

    val out = linkedMapOf<String, Any?>()

    val fetchdef: MutableMap<String, Any?>
    try {
      fetchdef = this.prepare(fetchargs)
    } catch (err: RuntimeException) {
      out["ok"] = false
      out["err"] = err
      return out
    }

    val url = fetchdef["url"]
    val fetched: Any?
    try {
      fetched = utility.fetcher(ctx, if (url is String) url else "", fetchdef)
    } catch (err: RuntimeException) {
      out["ok"] = false
      out["err"] = err
      return out
    }

    if (fetched == null) {
      out["ok"] = false
      out["err"] = ctx.makeError("direct_no_response", "response: undefined")
      return out
    }

    if (fetched is MutableMap<*, *>) {
      val fm = fetched as MutableMap<String, Any?>
      val status = Helpers.toInt(Struct.getprop(fm, "status"))
      val headers = Struct.getprop(fm, "headers")

      // No-body responses (204, 304) and explicit zero content-length
      // must skip JSON parsing — parsing an empty body errors.
      var contentLength = ""
      if (headers is MutableMap<*, *>) {
        val cl = (headers as MutableMap<String, Any?>)["content-length"]
        if (cl != null) {
          contentLength = cl.toString()
        }
      }
      val noBody = status == 204 || status == 304 || "0" == contentLength

      var jsonData: Any? = null
      if (!noBody) {
        val jf = Struct.getprop(fm, "json")
        if (jf is Supplier<*>) {
          // The supplier returns null on parse error in our fetcher.
          jsonData = (jf as Supplier<Any?>).get()
        }
      }

      out["ok"] = status in 200..299
      out["status"] = status
      out["headers"] = headers
      out["data"] = jsonData
      return out
    }

    out["ok"] = false
    out["err"] = ctx.makeError("direct_invalid", "invalid response type")
    return out
  }

  companion object {
    /** Builds SDK options with the test feature enabled (shared by testSDK). */
    @JvmStatic
    fun testOptions(
      testopts: MutableMap<String, Any?>?,
      sdkopts: MutableMap<String, Any?>?,
    ): MutableMap<String, Any?> {
      val sopts = if (sdkopts == null) {
        linkedMapOf()
      } else {
        Struct.clone(sdkopts) as MutableMap<String, Any?>
      }

      val topts = if (testopts == null) {
        linkedMapOf<String, Any?>()
      } else {
        Struct.clone(testopts) as MutableMap<String, Any?>
      }
      topts["active"] = true

      Struct.setpath(sopts, listOf("feature", "test"), topts)

      return sopts
    }
  }
}
