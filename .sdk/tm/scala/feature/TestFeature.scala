package SCALAPACKAGE.feature

import java.util.{LinkedHashMap, List => JList, Map => JMap}
import java.util.concurrent.ThreadLocalRandom
import java.util.function.Supplier
import SCALAPACKAGE.core.{Context, FetcherFn, Helpers, Operation, SdkClient}
import SCALAPACKAGE.utility.struct.Struct

// In-memory mock transport for offline testing. Serves entity fixtures
// (options.entity) through the normal pipeline, and optionally simulates
// network conditions via the `net` block.
class TestFeature extends BaseFeature("test", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var netcalls: Int = 0

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options

    val entity = Helpers.toMapAny(Struct.getprop(options, "entity"))

    this.client.mode = "test"

    // Ensure entity ids are correct.
    Struct.walk(entity, (key: String, valx: Object, parent: Object, path: java.util.List[String]) => {
      if (path != null && path.size() == 2 && valx.isInstanceOf[JMap[_, _]] && key != null) {
        valx.asInstanceOf[JMap[String, Object]].put("id", key)
      }
      valx
    })

    val entities: JMap[String, Object] = if (entity == null) new LinkedHashMap[String, Object]() else entity

    val testFetcher: FetcherFn = (fctx, fullurl, fetchdef) => serve(fctx, entities)

    val net = Helpers.toMapAny(Struct.getprop(options, "net"))
    if (net == null) ctx.utility.fetcher = testFetcher
    else ctx.utility.fetcher = makeNetsim(net, testFetcher)
  }

  private def respond(status: Int, data: Object, extra: JMap[String, Object]): JMap[String, Object] = {
    val js: Supplier[Object] = () => data
    val out = new LinkedHashMap[String, Object]()
    out.put("status", java.lang.Integer.valueOf(status))
    out.put("statusText", "OK")
    out.put("json", js)
    out.put("body", "not-used")
    if (extra != null) out.putAll(extra)
    out
  }

  private def extra(key: String, v: Object): JMap[String, Object] = {
    val out = new LinkedHashMap[String, Object]()
    out.put(key, v)
    out
  }

  private def resolveMatch(ctx: Context, explicit: JMap[String, Object]): JMap[String, Object] = {
    if (explicit != null && !explicit.isEmpty) return explicit
    val srcs = Array(ctx.matchData, ctx.data)
    var i = 0
    while (i < srcs.length) {
      val src = srcs(i)
      if (src != null) {
        val v = Struct.getprop(src, "id", null)
        if (v != null && !("__UNDEFINED__" == v)) {
          val out = new LinkedHashMap[String, Object]()
          out.put("id", v)
          return out
        }
      }
      i += 1
    }
    new LinkedHashMap[String, Object]()
  }

  private def serve(ctx: Context, entity: JMap[String, Object]): Object = {
    val op = ctx.op
    var entmap = Helpers.toMapAny(Struct.getprop(entity, op.entity))
    if (entmap == null) entmap = new LinkedHashMap[String, Object]()

    if ("load" == op.name) {
      val args = buildArgs(ctx, op, resolveMatch(ctx, ctx.reqmatch))
      val found = Struct.select(entmap, args)
      val ent = Struct.getelem(found, java.lang.Integer.valueOf(0))
      if (ent == null) return respond(404, null, extra("statusText", "Not found"))
      Struct.delprop(ent, "$KEY")
      val out = Struct.clone(ent)
      respond(200, out, null)
    } else if ("list" == op.name) {
      val args = buildArgs(ctx, op, ctx.reqmatch)
      val found = Struct.select(entmap, args)
      if (found == null) return respond(404, null, extra("statusText", "Not found"))
      val it = found.iterator()
      while (it.hasNext) Struct.delprop(it.next(), "$KEY")
      val out = Struct.clone(found)
      respond(200, out, null)
    } else if ("update" == op.name) {
      var updateMatch = new LinkedHashMap[String, Object]()
      if (ctx.reqdata != null) {
        if (ctx.reqdata.containsKey("id")) updateMatch.put("id", ctx.reqdata.get("id"))
        if (op.alias != null) {
          Struct.getprop(op.alias, "id") match {
            case aliasId: String if ctx.reqdata.containsKey(aliasId) => updateMatch.put(aliasId, ctx.reqdata.get(aliasId))
            case _ =>
          }
        }
      }
      if (updateMatch.isEmpty) updateMatch = resolveMatch(ctx, new LinkedHashMap[String, Object]()).asInstanceOf[LinkedHashMap[String, Object]]
      val args = buildArgs(ctx, op, updateMatch)
      val found = Struct.select(entmap, args)
      var ent = Struct.getelem(found, java.lang.Integer.valueOf(0))
      if (ent == null && entmap != null) {
        val vit = entmap.values().iterator()
        var brk = false
        while (vit.hasNext && !brk) {
          vit.next() match { case e: JMap[_, _] => ent = e; brk = true; case _ => }
        }
      }
      if (ent == null) return respond(404, null, extra("statusText", "Not found"))
      ent match { case m: JMap[_, _] if ctx.reqdata != null => m.asInstanceOf[JMap[String, Object]].putAll(ctx.reqdata); case _ => }
      Struct.delprop(ent, "$KEY")
      val out = Struct.clone(ent)
      respond(200, out, null)
    } else if ("remove" == op.name) {
      val args = buildArgs(ctx, op, resolveMatch(ctx, ctx.reqmatch))
      val found = Struct.select(entmap, args)
      val ent = Struct.getelem(found, java.lang.Integer.valueOf(0))
      ent match {
        case m: JMap[_, _] =>
          val id = Struct.getprop(m, "id", null)
          Struct.delprop(entmap, id)
        case _ =>
      }
      respond(200, null, null)
    } else if ("create" == op.name) {
      buildArgs(ctx, op, ctx.reqdata)
      var id = ctx.utility.param(ctx, "id")
      if (id == null) {
        val r = ThreadLocalRandom.current()
        id = String.format("%04x%04x%04x%04x",
          java.lang.Integer.valueOf(r.nextInt(0x10000)), java.lang.Integer.valueOf(r.nextInt(0x10000)),
          java.lang.Integer.valueOf(r.nextInt(0x10000)), java.lang.Integer.valueOf(r.nextInt(0x10000)))
      }

      val ent = Struct.clone(ctx.reqdata)
      ent match {
        case entm0: JMap[_, _] =>
          val entm = entm0.asInstanceOf[JMap[String, Object]]
          entm.put("id", id)
          id match { case s: String => entmap.put(s, entm); case _ => }
          Struct.delprop(entm, "$KEY")
          val out = Struct.clone(entm)
          respond(200, out, null)
        case _ => respond(200, ent, null)
      }
    } else {
      respond(404, null, extra("statusText", "Unknown operation"))
    }
  }

  private def makeNetsim(net: JMap[String, Object], inner: FetcherFn): FetcherFn = {
    this.netcalls = 0
    (ctx, url, fetchdef) => {
      this.netcalls += 1
      val call = this.netcalls

      if (FeatureOptions.foptBool(net, "offline", false)) {
        netSleep(net, pickLatency(net))
        throw ctx.makeError("netsim_offline", "Simulated network offline (URL was: \"" + url + "\")")
      }
      if (call <= FeatureOptions.foptInt(net, "errorTimes", 0)) {
        netSleep(net, pickLatency(net))
        throw ctx.makeError("netsim_conn", "Simulated connection error (call " + call + ")")
      }
      if (call <= FeatureOptions.foptInt(net, "failTimes", 0)) {
        netSleep(net, pickLatency(net))
        val status = FeatureOptions.foptInt(net, "failStatus", 503)
        val js: Supplier[Object] = () => null
        val out = new LinkedHashMap[String, Object]()
        out.put("status", java.lang.Integer.valueOf(status))
        out.put("statusText", "Simulated Failure")
        out.put("body", "not-used")
        out.put("json", js)
        out.put("headers", new LinkedHashMap[String, Object]())
        out
      } else {
        netSleep(net, pickLatency(net))
        inner(ctx, url, fetchdef)
      }
    }
  }

  private def pickLatency(net: JMap[String, Object]): Int = {
    net.get("latency") match {
      case null => 0
      case lm0: JMap[_, _] =>
        val lm = lm0.asInstanceOf[JMap[String, Object]]
        val min = FeatureOptions.foptInt(lm, "min", 0)
        val max = FeatureOptions.foptInt(lm, "max", min)
        if (max <= min) min else min + ((max - min) >> 1)
      case _ =>
        val fixed = FeatureOptions.foptInt(net, "latency", 0)
        if (fixed < 0) 0 else fixed
    }
  }

  private def netSleep(net: JMap[String, Object], ms: Int): Unit = {
    if (ms <= 0) return
    FeatureOptions.foptSleep(net).accept(ms)
  }

  private def buildArgs(ctx: Context, op: Operation, args: JMap[String, Object]): Object = {
    val opname = op.name

    // Pick the entity's own endpoint from config, not a cross-reference from
    // another resource that also returns it — the same rule makePoint falls
    // back to, so the seed-data query is built from the endpoint the request
    // will actually be sent to: a terminal `{id}` marks a record route, and
    // failing that the shallower path wins.
    val points = Struct.getpath(ctx.config,
      java.util.List.of("entity", if (ctx.entity == null) "" else ctx.entity.getName(), "op", opname, "points"))
    var point = Struct.getelem(points, java.lang.Integer.valueOf(0))
    points match {
      case plist: java.util.List[_] =>
        def pointPartsLen(p: Object): Int =
          Struct.getprop(p, "parts") match {
            case parts: java.util.List[_] => parts.size()
            case _ => 0
          }
        def pointTerminalParam(p: Object): Boolean =
          Struct.getprop(p, "parts") match {
            case parts: java.util.List[_] if parts.size() > 0 =>
              parts.get(parts.size() - 1) match {
                case s: String => s.startsWith("{")
                case _ => false
              }
            case _ => false
          }
        var k = 0
        while (k < plist.size()) {
          val cand = plist.get(k).asInstanceOf[Object]
          val candTerm = pointTerminalParam(cand)
          val bestTerm = pointTerminalParam(point)
          if (candTerm != bestTerm) {
            if (candTerm) point = cand
          } else if (pointPartsLen(cand) < pointPartsLen(point)) {
            point = cand
          }
          k += 1
        }
      case _ =>
    }

    val paramsPath = Struct.getpath(point, java.util.List.of("args", "params"))
    val reqdParams = Struct.select(paramsPath, Struct.jm("reqd", java.lang.Boolean.TRUE))
    val reqd = Struct.transform(reqdParams, Struct.jt("`$EACH`", "", "`$KEY.name`"))

    val qand = Struct.jt()
    val q = Struct.jm("`$AND`", qand)

    if (args != null) {
      val kit = Struct.keysof(args).iterator()
      while (kit.hasNext) {
        val key = kit.next()
        val isId = "id" == key
        val selected = Struct.select(reqd, key)
        val isReqd = !Struct.isempty(selected)

        if (isId || isReqd) {
          val v = ctx.utility.param(ctx, key)
          val ka = Struct.getprop(op.alias, key)

          val qor = Struct.jt(Struct.jm(key, v))
          ka match { case s: String => qor.add(Struct.jm(s, v)); case _ => }

          qand.add(Struct.jm("`$OR`", qor))
        }
      }
    }

    if (ctx.ctrl.explain != null) ctx.ctrl.explain.put("test", Struct.jm("query", q))

    q
  }
}
