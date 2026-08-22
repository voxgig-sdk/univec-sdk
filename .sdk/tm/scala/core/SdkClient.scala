package SCALAPACKAGE.core

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.function.Supplier
import SCALAPACKAGE.utility.struct.Struct

// Shared client runtime for the Univec SDK. The generated
// UnivecSDK class extends this with the API-specific entity accessors.
abstract class SdkClient(options0: JMap[String, Object]) {

  var mode: String = "live"
  var features: JList[Feature] = new ArrayList[Feature]()

  protected var options: JMap[String, Object] = null
  protected var utility: Utility = new Utility()
  protected var rootctx: Context = null

  locally {
    // The process-wide config (sdkgen rung L2): read-only on the request path,
    // so every client shares one rather than rebuilding it.
    val config = Config.sharedConfig()

    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("client", this)
    ctxmap.put("utility", this.utility)
    ctxmap.put("config", config)
    if (options0 != null) ctxmap.put("options", options0)
    ctxmap.put("shared", new LinkedHashMap[String, Object]())

    this.rootctx = this.utility.makeContext(ctxmap, null)

    this.options = this.utility.makeOptions(this.rootctx)

    if (java.lang.Boolean.TRUE == Struct.getpath(this.options,
        java.util.List.of("feature", "test", "active"))) {
      this.mode = "test"
    }

    this.rootctx.options = this.options

    // Add features in the resolved order (makeOptions puts an explicit list
    // order first, else defaults to test-first). Ordering matters: the `test`
    // feature installs the base mock transport and the transport features
    // (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
    // must be added before them to sit at the base of the chain.
    var featureOpts = Helpers.toMapAny(Struct.getprop(this.options, "feature"))
    if (featureOpts == null) featureOpts = new LinkedHashMap[String, Object]()
    Struct.getpath(this.options, java.util.List.of("__derived__", "featureorder")) match {
      case order: JList[_] =>
        val it = order.asInstanceOf[JList[Object]].iterator()
        while (it.hasNext) {
          val fname = it.next() match { case s: String => s; case _ => null }
          val fopts = Helpers.toMapAny(Struct.getprop(featureOpts, fname))
          if (fname != null && fopts != null && (java.lang.Boolean.TRUE == fopts.get("active"))) {
            val f = Config.makeFeature(fname)
            if (f != null) this.utility.featureAdd(this.rootctx, f)
          }
        }
      case _ =>
    }

    // Add extension features.
    Struct.getprop(this.options, "extend") match {
      case ext: JList[_] =>
        val it = ext.asInstanceOf[JList[Object]].iterator()
        while (it.hasNext) {
          it.next() match { case f: Feature => this.utility.featureAdd(this.rootctx, f); case _ => }
        }
      case _ =>
    }

    // Initialize features.
    val fit = new ArrayList[Feature](this.features).iterator()
    while (fit.hasNext) this.utility.featureInit(this.rootctx, fit.next())

    this.utility.featureHook(this.rootctx, "PostConstruct")
  }

  def optionsMap(): JMap[String, Object] = Struct.clone(this.options) match {
    case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
    case _ => new LinkedHashMap[String, Object]()
  }

  def getUtility(): Utility = this.utility.copy()

  def getRootCtx(): Context = this.rootctx

  def prepare(fetchargs0: JMap[String, Object]): JMap[String, Object] = {
    val utility = this.utility
    val fetchargs = if (fetchargs0 == null) new LinkedHashMap[String, Object]() else fetchargs0

    var ctrl = Helpers.toMapAny(Struct.getprop(fetchargs, "ctrl"))
    if (ctrl == null) ctrl = new LinkedHashMap[String, Object]()

    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("opname", "prepare")
    ctxmap.put("ctrl", ctrl)
    val ctx = utility.makeContext(ctxmap, this.rootctx)

    val opts = this.options

    val path = Struct.getprop(fetchargs, "path") match { case s: String => s; case _ => "" }
    var method = Struct.getprop(fetchargs, "method") match { case s: String => s; case _ => "" }
    if ("" == method) method = "GET"

    var params = Helpers.toMapAny(Struct.getprop(fetchargs, "params"))
    if (params == null) params = new LinkedHashMap[String, Object]()
    var query = Helpers.toMapAny(Struct.getprop(fetchargs, "query"))
    if (query == null) query = new LinkedHashMap[String, Object]()

    val headers = utility.prepareHeaders(ctx)

    val base = Struct.getprop(opts, "base")
    val prefix = Struct.getprop(opts, "prefix")
    val suffix = Struct.getprop(opts, "suffix")

    val specmap = new LinkedHashMap[String, Object]()
    specmap.put("base", base match { case s: String => s; case _ => "" })
    specmap.put("prefix", prefix match { case s: String => s; case _ => "" })
    specmap.put("suffix", suffix match { case s: String => s; case _ => "" })
    specmap.put("path", path)
    specmap.put("method", method)
    specmap.put("params", params)
    specmap.put("query", query)
    specmap.put("headers", headers)
    specmap.put("body", Struct.getprop(fetchargs, "body", null))
    specmap.put("step", "start")
    ctx.spec = new Spec(specmap)

    val uheaders = Helpers.toMapAny(Struct.getprop(fetchargs, "headers"))
    if (uheaders != null) ctx.spec.headers.putAll(uheaders)

    utility.prepareAuth(ctx)

    utility.makeFetchDef(ctx)
  }

  // Raw endpoint access is operator-controllable, like every entity op.
  // Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
  // either one reaches the same endpoint.
  def direct(fetchargs0: JMap[String, Object]): JMap[String, Object] = {
    if (!opAllowed("direct")) opDenied("direct")
    else rawRequest(fetchargs0)
  }

  // Is this raw-access op permitted by the SDK's allow.op option?
  private def opAllowed(op: String): Boolean =
    Struct.getpath(this.options, java.util.List.of("allow", "op")) match {
      case s: String => s.contains(op)
      case _ => false
    }

  private def opDenied(op: String): JMap[String, Object] = {
    val allow = Struct.getpath(this.options, java.util.List.of("allow", "op")) match {
      case s: String => s
      case _ => ""
    }
    val out = new LinkedHashMap[String, Object]()
    out.put("ok", java.lang.Boolean.FALSE)
    out.put("err", new SdkError(op + "_allow",
      "UnivecSDK: " + op + ": operation not allowed by" +
        " SDK option allow.op value: \"" + allow + "\"", null))
    out
  }

  // Raw GraphQL access: the pressure valve that makes the generated surface's
  // deliberate omissions (per-call selection sets, typed filter builders,
  // batching, subscriptions) livable — the whole schema stays reachable.
  //
  // Thin wrapper over the same prepare/fetch path direct uses, with the one
  // thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200
  // as a top-level `errors` array, so status alone would report a failed
  // query as ok.
  //
  // NOTE: like direct, this bypasses the feature pipeline — no retry,
  // ratelimit or paging features apply.
  def graphql(
    query: String,
    variables: JMap[String, Object] = null,
    ctrl: JMap[String, Object] = null,
  ): JMap[String, Object] = {
    if (!opAllowed("graphql")) opDenied("graphql")
    else {
      val headers = new LinkedHashMap[String, Object]()
      headers.put("content-type", "application/json")

      val body = new LinkedHashMap[String, Object]()
      body.put("query", query)
      body.put("variables",
        if (variables == null) new LinkedHashMap[String, Object]() else variables)

      val fetchargs = new LinkedHashMap[String, Object]()
      fetchargs.put("method", "POST")
      fetchargs.put("headers", headers)
      fetchargs.put("body", body)
      fetchargs.put("ctrl",
        if (ctrl == null) new LinkedHashMap[String, Object]() else ctrl)

      val res = rawRequest(fetchargs)

      // Errors are read BEFORE any status check: a GraphQL parse or
      // validation failure comes back as HTTP 400 carrying the standard
      // { errors: [...] } body, and the raw path represents a non-2xx as
      // ok:false with no err — so returning early on status would discard
      // the server's own diagnostics, which are the only useful part of that
      // response.
      Struct.getpath(res, java.util.List.of("data", "errors")) match {
        case errors: JList[_] if !errors.isEmpty =>
          val msg = Struct.getprop(errors.get(0), "message") match {
            case m: String if m.nonEmpty => m
            case _ => "graphql error"
          }
          res.put("ok", java.lang.Boolean.FALSE)
          res.put("err", new SdkError("graphql_error",
            "UnivecSDK: graphql: " + msg, null))
          res.put("graphql", errors.asInstanceOf[Object])
        case _ =>
      }

      res
    }
  }

  // Ungated request path shared by direct and graphql, each of which checks
  // its own allow.op token first. Private, rather than a flag on fetchargs: a
  // caller-supplied marker would let anyone opt straight back out of the gate
  // by passing it.
  private def rawRequest(fetchargs0: JMap[String, Object]): JMap[String, Object] = {
    val utility = this.utility
    val fetchargs = if (fetchargs0 == null) new LinkedHashMap[String, Object]() else fetchargs0

    var ctrl = Helpers.toMapAny(Struct.getprop(fetchargs, "ctrl"))
    if (ctrl == null) ctrl = new LinkedHashMap[String, Object]()

    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("opname", "direct")
    ctxmap.put("ctrl", ctrl)
    val ctx = utility.makeContext(ctxmap, this.rootctx)

    val out = new LinkedHashMap[String, Object]()

    val fetchdef =
      try this.prepare(fetchargs)
      catch { case err: RuntimeException =>
        out.put("ok", java.lang.Boolean.FALSE); out.put("err", err); return out
      }

    val url = fetchdef.get("url")
    val fetched =
      try utility.fetcher(ctx, url match { case s: String => s; case _ => "" }, fetchdef)
      catch { case err: RuntimeException =>
        out.put("ok", java.lang.Boolean.FALSE); out.put("err", err); return out
      }

    if (fetched == null) {
      out.put("ok", java.lang.Boolean.FALSE)
      out.put("err", ctx.makeError("direct_no_response", "response: undefined"))
      return out
    }

    fetched match {
      case fm0: JMap[_, _] =>
        val fm = fm0.asInstanceOf[JMap[String, Object]]
        val status = Helpers.toInt(Struct.getprop(fm, "status"))
        val headers = Struct.getprop(fm, "headers")

        var contentLength = ""
        headers match {
          case hm: JMap[_, _] =>
            val cl = hm.asInstanceOf[JMap[String, Object]].get("content-length")
            if (cl != null) contentLength = String.valueOf(cl)
          case _ =>
        }
        val noBody = status == 204 || status == 304 || "0" == contentLength

        var jsonData: Object = null
        if (!noBody) {
          Struct.getprop(fm, "json") match {
            case jf: Supplier[_] => jsonData = jf.asInstanceOf[Supplier[Object]].get()
            case _ =>
          }
        }

        out.put("ok", java.lang.Boolean.valueOf(status >= 200 && status < 300))
        out.put("status", java.lang.Integer.valueOf(status))
        out.put("headers", headers)
        out.put("data", jsonData)
        out
      case _ =>
        out.put("ok", java.lang.Boolean.FALSE)
        out.put("err", ctx.makeError("direct_invalid", "invalid response type"))
        out
    }
  }
}

object SdkClient {
  // Builds SDK options with the test feature enabled (shared by testSDK).
  def testOptions(testopts: JMap[String, Object], sdkopts: JMap[String, Object]): JMap[String, Object] = {
    val sopts: JMap[String, Object] =
      if (sdkopts == null) new LinkedHashMap[String, Object]()
      else Struct.clone(sdkopts).asInstanceOf[JMap[String, Object]]

    val topts: JMap[String, Object] =
      if (testopts == null) new LinkedHashMap[String, Object]()
      else Struct.clone(testopts).asInstanceOf[JMap[String, Object]]
    topts.put("active", java.lang.Boolean.TRUE)

    Struct.setpath(sopts, java.util.List.of("feature", "test"), topts)
    sopts
  }
}
