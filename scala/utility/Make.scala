package voxgig.univecsdk.utility

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.Objects
import voxgig.univecsdk.core._
import voxgig.univecsdk.utility.struct.Struct

// makeError finalises a failed operation: wraps the causing error in an
// SdkError carrying the cleaned result and spec, records it on ctx.ctrl, and
// either throws it (default) or — when ctrl.throw is false — returns the
// result's fallback resdata instead.
object MakeError {
  def makeError(ctx0: Context, err0: RuntimeException): Object = {
    val ctx = if (ctx0 == null) new Context(new LinkedHashMap[String, Object](), null) else ctx0

    var opname = if (ctx.op == null) "" else ctx.op.name
    if ("" == opname || "_" == opname) opname = "unknown operation"

    var result = ctx.result
    if (result == null) result = new Result(new LinkedHashMap[String, Object]())
    result.ok = false

    var err = err0
    if (err == null) err = result.err
    if (err == null) err = ctx.makeError("unknown", "unknown error")

    val errmsg = if (err.getMessage == null) String.valueOf(err) else err.getMessage
    var msg = "UnivecSDK: " + opname + ": " + errmsg
    msg = Clean.clean(ctx, msg).asInstanceOf[String]

    result.err = null

    val spec = ctx.spec

    if (ctx.ctrl.explain != null) {
      val errRecord = new LinkedHashMap[String, Object]()
      errRecord.put("message", msg)
      ctx.ctrl.explain.put("err", errRecord)
    }

    var code = ""
    err match { case e: SdkError => code = e.code; case _ => }

    val sdkErr = new SdkError(code, msg, ctx)
    sdkErr.result = Clean.clean(ctx, result)
    sdkErr.spec = Clean.clean(ctx, spec)

    ctx.ctrl.err = sdkErr

    // Fire PreUnexpected so observability features (metrics, telemetry, audit,
    // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
    // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
    // error; features guard against double-recording when PreDone already fired.
    if (ctx.utility != null && ctx.utility.featureHook != null) {
      ctx.utility.featureHook(ctx, "PreUnexpected")
    }

    if (java.lang.Boolean.FALSE == ctx.ctrl.throwing) return result.resdata

    throw sdkErr
  }
}

object MakePoint {
  def makePoint(ctx: Context): JMap[String, Object] = {
    val outPoint = ctx.out.get("point")
    if (outPoint != null) {
      // A PrePoint feature hook (e.g. rbac) may short-circuit by storing an
      // error here; surface it before any endpoint resolution.
      outPoint match {
        case e: RuntimeException => throw e
        case m: JMap[_, _] => ctx.point = m.asInstanceOf[JMap[String, Object]]; return ctx.point
        case _ =>
      }
    }

    val op = ctx.op
    val options = ctx.options

    val allowOp = Struct.getpath(options, java.util.List.of("allow", "op")) match { case s: String => s; case _ => "" }
    if (!allowOp.contains(op.name)) {
      throw ctx.makeError("point_op_allow",
        "Operation \"" + op.name + "\" not allowed by SDK option allow.op value: \"" + allowOp + "\"")
    }

    if (op.points.isEmpty) {
      throw ctx.makeError("point_no_points", "Operation \"" + op.name + "\" has no endpoint definitions.")
    }

    if (op.points.size() == 1) {
      ctx.point = op.points.get(0)
    } else {
      val reqselector: JMap[String, Object] = if ("data" == op.input) ctx.reqdata else ctx.reqmatch
      val selector: JMap[String, Object] = if ("data" == op.input) ctx.data else ctx.matchData

      var point: JMap[String, Object] = null
      var matched = false
      var i = 0
      var break = false
      while (i < op.points.size() && !break) {
        val cand = op.points.get(i)
        val selectDef = Helpers.toMapAny(Struct.getprop(cand, "select"))
        var found = true

        if (selector != null && selectDef != null) {
          Struct.getprop(selectDef, "exist") match {
            case exist: JList[_] =>
              val eit = exist.asInstanceOf[JList[Object]].iterator()
              var ebreak = false
              while (eit.hasNext && !ebreak) {
                val existkey = eit.next() match { case s: String => s; case _ => "" }
                val rv = Struct.getprop(reqselector, existkey, null)
                val sv = Struct.getprop(selector, existkey, null)
                if (rv == null && sv == null) { found = false; ebreak = true }
              }
            case _ =>
          }
        }

        if (found) {
          val reqAction = Struct.getprop(reqselector, "$action", null)
          val selectAction = Struct.getprop(selectDef, "$action", null)
          if (!Objects.equals(reqAction, selectAction)) found = false
        }

        if (found) { point = cand; matched = true; break = true } else i += 1
      }

      // select.exist can list more than the params needed to pick a point
      // (for /boards/{id} it is Trello's 17 optional query-includes), so a
      // plain {id} call matches NOTHING. Fall back to the entity's own route
      // rather than whichever point came last.
      if (!matched) {
        // A request naming an action reaches here only because that action's
        // own point failed its exist test, so it is unbuildable whatever we
        // pick. Refuse it BEFORE choosing a fallback: the guard below
        // compares the chosen point's $action and would wave the request
        // through whenever the fallback lands on the action point itself.
        val unmatchedAction =
          if (reqselector != null) Struct.getprop(reqselector, "$action", null) else null
        if (unmatchedAction != null) {
          throw ctx.makeError("point_action_invalid",
            "Operation \"" + op.name + "\" action \"" +
              Struct.stringify(unmatchedAction) + "\" is not valid.")
        }

        // A terminal parameter marks a record route (/boards/{id}); a
        // cross-reference ends in the relationship's name
        // (/posts/{id}/author). Failing that, the shallower path wins. The
        // same rule runs at generation time, in helpers/opShape.ts — both
        // sides must move together.
        def partsLen(p: JMap[String, Object]): Int =
          Struct.getprop(p, "parts") match {
            case parts: JList[_] => parts.size()
            case _ => 0
          }
        def terminalParam(p: JMap[String, Object]): Boolean =
          Struct.getprop(p, "parts") match {
            case parts: JList[_] if parts.size() > 0 =>
              parts.get(parts.size() - 1) match {
                case s: String => s.startsWith("{")
                case _ => false
              }
            case _ => false
          }

        point = op.points.get(0)
        var j = 0
        while (j < op.points.size()) {
          val cand = op.points.get(j)
          val candTerm = terminalParam(cand)
          val bestTerm = terminalParam(point)
          if (candTerm != bestTerm) {
            if (candTerm) point = cand
          } else if (partsLen(cand) < partsLen(point)) {
            point = cand
          }
          j += 1
        }
      }

      if (reqselector != null) {
        val reqAction = Struct.getprop(reqselector, "$action", null)
        if (reqAction != null && point != null) {
          val pointSelect = Helpers.toMapAny(Struct.getprop(point, "select"))
          val pointAction = Struct.getprop(pointSelect, "$action", null)
          if (!Objects.equals(reqAction, pointAction)) {
            throw ctx.makeError("point_action_invalid",
              "Operation \"" + op.name + "\" action \"" + Struct.stringify(reqAction) + "\" is not valid.")
          }
        }
      }

      ctx.point = point
    }

    ctx.point
  }
}

object MakeOptions {

  /**
   * Replaces one utility member from `options.utility`, matching the ts
   * reference: a key naming a real member REPLACES it, and any other key is
   * attached as a custom extra. Returns false when the key names no member or
   * the value is not that member's type, so the caller keeps it in `custom`.
   *
   * REFLECTION, NOT A KEYED SWITCH. The go and java ports list every member by
   * hand and carry a "keep this in step with registerAll" warning, because a
   * utility added to one list and not the other is overridable there and not
   * here. The field set is readable off the class, so the list cannot drift.
   *
   * Scala `var` fields compile to a private field plus accessors, so the
   * lookup is on the declared field and needs setAccessible. Function types
   * erase on the JVM, so isInstance checks the FunctionN arity rather than the
   * full signature - the same limit java's port documents.
   *
   * Only a PUBLIC name may replace a member: public utility names are
   * camelCase and carry no underscore, so an underscore means the caller named
   * something of their own rather than a member.
   */
  def overrideUtil(utility: Utility, key: String, value: Object): Boolean = {
    if (null == key || key.isEmpty || key.contains("_") || "custom" == key) return false
    if (null == value) return false

    try {
      val field = classOf[Utility].getDeclaredField(key)
      if (!field.getType.isInstance(value)) return false
      field.setAccessible(true)
      field.set(utility, value)
      true
    }
    catch {
      case _: NoSuchFieldException => false
    }
  }

  def makeOptions(ctx: Context): JMap[String, Object] = {
    var options = ctx.options
    if (options == null) options = new LinkedHashMap[String, Object]()

    // Merge utility overrides from options onto the utility object.
    //
    // A key naming a real utility member REPLACES it; anything else is
    // attached as a custom extra. Shelving everything in `custom` - a map
    // nothing reads - made `utility -> Map("fetcher" -> ...)`, the documented
    // transport seam, a silent no-op here while ts honoured it.
    val customUtils = Helpers.toMapAny(options.get("utility"))
    if (customUtils != null && ctx.utility != null) {
      customUtils.entrySet().forEach { e =>
        if (!overrideUtil(ctx.utility, e.getKey, e.getValue))
          ctx.utility.custom.put(e.getKey, e.getValue)
      }
    }

    // `auth: null` is the documented way to suppress auth outright, and
    // prepareAuth honours it before it ever reads the apikey. It cannot survive
    // validate: a stored null reads as "no value", so the optspec `auth`
    // default fires and the suppression becomes "use the default auth" -
    // transmitting the credential the caller withheld. Withhold the key for
    // validate, then put the null back. Same fix as ts/js/go/java makeOptions.
    //
    // Suppliedness cannot be recovered after validate, hence here, and it must
    // tell an ABSENT auth from a present null: containsKey rather than a get()
    // null check, which cannot distinguish them.
    val authSuppressed = options.containsKey("auth") && null == options.get("auth")

    var opts = Struct.clone(options).asInstanceOf[JMap[String, Object]]

    if (authSuppressed) opts.remove("auth")

    // Feature add-order. options.feature may be given as an ordered LIST of
    // { name, active, ...opts } entries (the list position IS the order in
    // which features are added), or as a { name: {opts} } map. Normalize a
    // list to a map (so merge/validate/init are unchanged) and remember the
    // explicit order; a map defaults to test-first so the `test` mock
    // transport is installed as the base of the transport wrapper chain.
    val featureorder = new ArrayList[Object]()
    opts.get("feature") match {
      case flist: JList[_] =>
        val fmap = new LinkedHashMap[String, Object]()
        val fit = flist.asInstanceOf[JList[Object]].iterator()
        while (fit.hasNext) {
          val em = Helpers.toMapAny(fit.next())
          if (em != null) {
            em.get("name") match {
              case fname: String if "" != fname =>
                val fopts = new LinkedHashMap[String, Object](em)
                fopts.remove("name")
                fmap.put(fname, fopts)
                featureorder.add(fname)
              case _ =>
            }
          }
        }
        opts.put("feature", fmap)
      case _ =>
    }

    var config = ctx.config
    if (config == null) config = new LinkedHashMap[String, Object]()
    var cfgopts = Helpers.toMapAny(config.get("options"))
    if (cfgopts == null) cfgopts = new LinkedHashMap[String, Object]()

    val optspec = Json.parse(
      "{"
        + "\"apikey\": \"\","
        + "\"base\": \"http://localhost:8000\","
        + "\"prefix\": \"\","
        + "\"suffix\": \"\","
        + "\"auth\": { \"prefix\": \"\" },"
        + "\"headers\": { \"`$CHILD`\": \"`$STRING`\" },"
        + "\"allow\": {"
        + "  \"method\": \"GET,PUT,POST,PATCH,DELETE,OPTIONS\","
        + "  \"op\": \"create,update,load,list,remove,command,direct,graphql\""
        + "},"
        + "\"entity\": { \"`$CHILD`\": {"
        + "  \"`$OPEN`\": true, \"active\": false, \"alias\": {} } },"
        + "\"feature\": { \"`$CHILD`\": {"
        + "  \"`$OPEN`\": true, \"active\": false } },"
        + "\"utility\": {},"
        // `extend` carries LIVE Feature objects a caller hands in, and an
        // optspec with no entry for a key makes Struct.validate DROP it -
        // silently, so `new Client(Map.of("extend", List.of(feature)))`
        // built a client with no such feature and nothing said so. `$ANY`
        // passes the list through untouched, which is what go's optspec
        // does (tm/go/utility/make_options.go).
        + "\"extend\": \"`$ANY`\","
        + "\"system\": {},"
        + "\"test\": { \"active\": false, \"entity\": { \"`$OPEN`\": true } },"
        + "\"clean\": { \"keys\": \"key,token,id\" }"
        + "}").asInstanceOf[JMap[String, Object]]

    // Preserve system.fetch before merge/validate.
    var sysFetch = Struct.getpath(opts, java.util.List.of("system", "fetch"))
    if (sysFetch eq Struct.UNDEF) sysFetch = null

    val mergeList = new ArrayList[Object]()
    mergeList.add(new LinkedHashMap[String, Object]())
    // CLONE the config side: `config` is a process-wide singleton
    // (Config.sharedConfig) and merge uses its nested maps as merge TARGETS, so
    // without this one client's options (headers, server, ...) are written into
    // the shared config and inherited by every client constructed afterwards.
    mergeList.add(Struct.clone(cfgopts))
    mergeList.add(opts)
    val merged = Struct.merge(mergeList)

    val vopts = new LinkedHashMap[String, Object]()
    vopts.put("errs", new ArrayList[Object]())
    val validated = Struct.validate(merged, optspec, vopts)
    opts = validated.asInstanceOf[JMap[String, Object]]

    // Restore the suppression the optspec default would otherwise erase.
    if (authSuppressed) opts.put("auth", null)

    // Restore system.fetch.
    if (sysFetch != null) {
      val sys = Helpers.toMapAny(opts.get("system"))
      if (sys != null) sys.put("fetch", sysFetch)
      else { val sm = new LinkedHashMap[String, Object](); sm.put("fetch", sysFetch); opts.put("system", sm) }
    }

    // Derived clean config.
    var cleanKeys = "key,token,id"
    Struct.getpath(opts, java.util.List.of("clean", "keys")) match { case s: String => cleanKeys = s; case _ => }

    val filtered = new ArrayList[String]()
    for (p0 <- cleanKeys.split(",")) {
      val p = p0.trim
      if ("" != p) filtered.add(Struct.escre(p))
    }
    val keyre = String.join("|", filtered)

    // Resolve the feature add-order: an explicit list order (above) wins;
    // otherwise order the map test-first, then the remaining names sorted, so
    // the outcome is deterministic and `test` is always the base transport.
    if (featureorder.isEmpty) {
      val fmap = Helpers.toMapAny(opts.get("feature"))
      val names = new ArrayList[String]()
      if (fmap != null) names.addAll(fmap.keySet())
      java.util.Collections.sort(names)
      if (names.contains("test")) {
        featureorder.add("test")
        val nit = names.iterator()
        while (nit.hasNext) { val n = nit.next(); if ("test" != n) featureorder.add(n) }
      } else {
        featureorder.addAll(names)
      }
    }

    val derived = new LinkedHashMap[String, Object]()
    val derivedClean = new LinkedHashMap[String, Object]()
    if ("" != keyre) derivedClean.put("keyre", keyre)
    derived.put("clean", derivedClean)
    derived.put("featureorder", featureorder)
    opts.put("__derived__", derived)

    opts
  }
}

object MakeFetchDef {
  def makeFetchDef(ctx: Context): JMap[String, Object] = {
    val spec = ctx.spec
    if (spec == null) throw ctx.makeError("fetchdef_no_spec", "Expected context spec property to be defined.")

    if (ctx.result == null) ctx.result = new Result(new LinkedHashMap[String, Object]())

    spec.step = "prepare"

    val url = ctx.utility.makeUrl(ctx)
    spec.url = url

    val fetchdef = new LinkedHashMap[String, Object]()
    fetchdef.put("url", url)
    fetchdef.put("method", spec.method)
    fetchdef.put("headers", spec.headers)

    if (spec.body != null) {
      spec.body match {
        case _: JMap[_, _] => fetchdef.put("body", Struct.jsonify(spec.body))
        case _ => fetchdef.put("body", spec.body)
      }
    }

    fetchdef
  }
}

object MakeRequest {
  def makeRequest(ctx: Context): Response = {
    ctx.out.get("request") match { case r: Response => return r; case _ => }

    val spec = ctx.spec
    val utility = ctx.utility

    var response = new Response(new LinkedHashMap[String, Object]())
    val result = new Result(new LinkedHashMap[String, Object]())
    ctx.result = result

    if (spec == null) throw ctx.makeError("request_no_spec", "Expected context spec property to be defined.")

    var fetchdef: JMap[String, Object] = null
    try fetchdef = utility.makeFetchDef(ctx)
    catch {
      case err: RuntimeException =>
        response.err = err; ctx.response = response; spec.step = "postrequest"; return response
    }

    if (ctx.ctrl.explain != null) ctx.ctrl.explain.put("fetchdef", fetchdef)

    spec.step = "prerequest"

    val url = fetchdef.get("url")
    var fetched: Object = null
    var fetchErr: RuntimeException = null
    try fetched = utility.fetcher(ctx, url match { case s: String => s; case _ => "" }, fetchdef)
    catch { case err: RuntimeException => fetchErr = err }

    if (fetchErr != null) response.err = fetchErr
    else if (fetched == null) {
      val resmap = new LinkedHashMap[String, Object]()
      resmap.put("err", ctx.makeError("request_no_response", "response: undefined"))
      response = new Response(resmap)
    } else fetched match {
      case m: JMap[_, _] => response = new Response(m.asInstanceOf[JMap[String, Object]])
      case _ => response.err = ctx.makeError("request_invalid_response", "response: invalid type")
    }

    spec.step = "postrequest"
    ctx.response = response
    response
  }
}

object MakeResponse {
  def makeResponse(ctx: Context): Response = {
    ctx.out.get("response") match { case r: Response => return r; case _ => }

    val utility = ctx.utility
    val spec = ctx.spec
    val result = ctx.result
    val response = ctx.response

    if (spec == null) throw ctx.makeError("response_no_spec", "Expected context spec property to be defined.")
    if (response == null) throw ctx.makeError("response_no_response", "Expected context response property to be defined.")
    if (result == null) throw ctx.makeError("response_no_result", "Expected context result property to be defined.")

    spec.step = "response"

    utility.resultBasic(ctx)
    utility.resultHeaders(ctx)
    utility.resultBody(ctx)

    // GraphQL reports failures as a top-level `errors` array under HTTP
    // 200, so resultBasic's status check never sees them. Lift them here,
    // before the response transform tries to unwrap data that is not there.
    utility.graphqlErrors(ctx)

    utility.transformResponse(ctx)

    if (result.err == null) result.ok = true

    if (ctx.ctrl.explain != null) ctx.ctrl.explain.put("result", result)

    response
  }
}

object MakeResult {
  def makeResult(ctx: Context): Result = {
    ctx.out.get("result") match { case r: Result => return r; case _ => }

    val utility = ctx.utility
    val op = ctx.op
    val entity = ctx.entity
    val spec = ctx.spec
    val result = ctx.result

    if (spec == null) throw ctx.makeError("result_no_spec", "Expected context spec property to be defined.")
    if (result == null) throw ctx.makeError("result_no_result", "Expected context result property to be defined.")

    spec.step = "result"

    utility.transformResponse(ctx)

    if ("list" == op.name) {
      val resdata = result.resdata
      result.resdata = new ArrayList[Object]()

      resdata match {
        case l: JList[_] if !l.isEmpty && entity != null =>
          val entities = new ArrayList[Object]()
          val it = l.asInstanceOf[JList[Object]].iterator()
          while (it.hasNext) {
            val entry = it.next()
            val ent = entity.make()
            entry match { case m: JMap[_, _] => ent.data(m); case _ => }
            entities.add(ent)
          }
          result.resdata = entities
        case _ =>
      }
    }

    if (ctx.ctrl.explain != null) ctx.ctrl.explain.put("result", result)

    result
  }
}

object MakeUrl {
  def makeUrl(ctx: Context): String = {
    val spec = ctx.spec
    val result = ctx.result

    if (spec == null) throw ctx.makeError("url_no_spec", "Expected context spec property to be defined.")
    if (result == null) throw ctx.makeError("url_no_result", "Expected context result property to be defined.")

    val joinParts = new ArrayList[Object]()
    joinParts.add(spec.base)
    joinParts.add(spec.prefix)
    joinParts.add(spec.path)
    joinParts.add(spec.suffix)
    var url = Struct.join(joinParts, "/", true)

    val resmatch = new LinkedHashMap[String, Object]()

    val pit = Struct.items(spec.params).iterator()
    while (pit.hasNext) {
      val item = pit.next()
      val key = item.get(0) match { case s: String => s; case _ => "" }
      val v = item.get(1)
      if (v != null) {
        url = url.replaceAll("\\{" + Struct.escre(key) + "\\}",
          java.util.regex.Matcher.quoteReplacement(Struct.escurl(Struct.stringify(v))))
        resmatch.put(key, v)
      }
    }

    var qsep = "?"
    val qit = Struct.items(spec.query).iterator()
    while (qit.hasNext) {
      val item = qit.next()
      val key = item.get(0) match { case s: String => s; case _ => "" }
      val v = item.get(1)
      if (v != null) {
        url += qsep + Struct.escurl(key) + "=" + Struct.escurl(Struct.stringify(v))
        qsep = "&"
        resmatch.put(key, v)
      }
    }

    result.resmatch = resmatch
    url
  }
}
