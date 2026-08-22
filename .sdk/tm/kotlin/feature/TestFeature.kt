package KOTLINPACKAGE.feature

import java.util.concurrent.ThreadLocalRandom
import java.util.function.Supplier

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.Operation
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.utility.struct.Struct

/**
 * In-memory mock transport for offline testing. Serves entity fixtures
 * (options.entity) through the normal pipeline, and optionally simulates
 * network conditions via the `net` block — mirroring the ts test feature.
 */
@Suppress("UNCHECKED_CAST")
class TestFeature : BaseFeature("test", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var netcalls = 0

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options

    val entity = Helpers.toMapAny(Struct.getprop(options, "entity"))

    this.client!!.mode = "test"

    // Ensure entity ids are correct.
    Struct.walk(
      entity,
      Struct.WalkApply { key, value, _, path ->
        if (path.size == 2 && value is MutableMap<*, *> && key != null) {
          (value as MutableMap<String, Any?>)["id"] = key
        }
        value
      },
    )

    val entities: MutableMap<String, Any?> = entity ?: linkedMapOf()

    val testFetcher: FetcherFn = { fctx, _, _ -> serve(fctx, entities) }

    // Optional network behaviour simulation over the mock transport.
    val net = Helpers.toMapAny(Struct.getprop(options, "net"))
    if (net == null) {
      ctx.utility!!.fetcher = testFetcher
    } else {
      ctx.utility!!.fetcher = makeNetsim(net, testFetcher)
    }
  }

  private fun respond(status: Int, data: Any?, extra: MutableMap<String, Any?>?): MutableMap<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    out["status"] = status
    out["statusText"] = "OK"
    out["json"] = Supplier<Any?> { data }
    out["body"] = "not-used"
    if (extra != null) {
      out.putAll(extra)
    }
    return out
  }

  private fun extra(key: String, value: Any?): MutableMap<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    out[key] = value
    return out
  }

  // For single-entity ops (load, remove) with an empty explicit match, fall
  // back to the id the entity client already knows from a prior create/load.
  private fun resolveMatch(ctx: Context, explicit: MutableMap<String, Any?>?): MutableMap<String, Any?> {
    if (explicit != null && explicit.isNotEmpty()) {
      return explicit
    }
    for (src in listOf(ctx.match, ctx.data)) {
      val v = Struct.getprop(src, "id", null)
      if (v != null && "__UNDEFINED__" != v) {
        val out = linkedMapOf<String, Any?>()
        out["id"] = v
        return out
      }
    }
    return linkedMapOf()
  }

  private fun serve(ctx: Context, entity: MutableMap<String, Any?>): Any? {
    val op = ctx.op
    var entmap = Helpers.toMapAny(Struct.getprop(entity, op.entity))
    if (entmap == null) {
      entmap = linkedMapOf()
    }

    when (op.name) {
      "load" -> {
        val args = buildArgs(ctx, op, resolveMatch(ctx, ctx.reqmatch))
        val found = Struct.select(entmap, args)
        val ent = Struct.getelem(found, 0, null)
        if (ent == null) {
          return respond(404, null, extra("statusText", "Not found"))
        }
        Struct.delprop(ent, "\$KEY")
        val out = Struct.clone(ent)
        return respond(200, out, null)
      }
      "list" -> {
        val args = buildArgs(ctx, op, ctx.reqmatch)
        val found = Struct.select(entmap, args)
        for (item in found) {
          Struct.delprop(item, "\$KEY")
        }
        val out = Struct.clone(found)
        return respond(200, out, null)
      }
      "update" -> {
        // Match the existing entity by id only (or its alias).
        var updateMatch: MutableMap<String, Any?> = linkedMapOf()
        val reqdata = ctx.reqdata
        if (reqdata.containsKey("id")) {
          updateMatch["id"] = reqdata["id"]
        }
        val alias = op.alias
        if (alias != null) {
          val aliasIdRaw = Struct.getprop(alias, "id")
          if (aliasIdRaw is String) {
            if (reqdata.containsKey(aliasIdRaw)) {
              updateMatch[aliasIdRaw] = reqdata[aliasIdRaw]
            }
          }
        }
        if (updateMatch.isEmpty()) {
          updateMatch = resolveMatch(ctx, linkedMapOf())
        }
        val args = buildArgs(ctx, op, updateMatch)
        val found = Struct.select(entmap, args)
        var ent = Struct.getelem(found, 0, null)
        if (ent == null) {
          for (e in entmap.values) {
            if (e is MutableMap<*, *>) {
              ent = e
              break
            }
          }
        }
        if (ent == null) {
          return respond(404, null, extra("statusText", "Not found"))
        }
        if (ent is MutableMap<*, *>) {
          (ent as MutableMap<String, Any?>).putAll(reqdata)
        }
        Struct.delprop(ent, "\$KEY")
        val out = Struct.clone(ent)
        return respond(200, out, null)
      }
      "remove" -> {
        val args = buildArgs(ctx, op, resolveMatch(ctx, ctx.reqmatch))
        val found = Struct.select(entmap, args)
        val ent = Struct.getelem(found, 0, null)
        // Remove only the first matched entity. If nothing matches, no-op.
        if (ent is MutableMap<*, *>) {
          val id = Struct.getprop(ent, "id", null)
          Struct.delprop(entmap, id)
        }
        return respond(200, null, null)
      }
      "create" -> {
        buildArgs(ctx, op, ctx.reqdata)
        var id = ctx.utility!!.param(ctx, "id")
        if (id == null) {
          val r = ThreadLocalRandom.current()
          id = String.format(
            "%04x%04x%04x%04x",
            r.nextInt(0x10000), r.nextInt(0x10000),
            r.nextInt(0x10000), r.nextInt(0x10000),
          )
        }

        val ent = Struct.clone(ctx.reqdata)
        if (ent is MutableMap<*, *>) {
          val entm = ent as MutableMap<String, Any?>
          entm["id"] = id
          if (id is String) {
            entmap[id] = entm
          }
          Struct.delprop(entm, "\$KEY")
          val out = Struct.clone(entm)
          return respond(200, out, null)
        }
        return respond(200, ent, null)
      }
    }

    return respond(404, null, extra("statusText", "Unknown operation"))
  }

  // makeNetsim wraps a transport with simulated network conditions.
  private fun makeNetsim(net: MutableMap<String, Any?>, inner: FetcherFn): FetcherFn {
    this.netcalls = 0

    return { ctx, url, fetchdef ->
      this.netcalls++
      val call = this.netcalls

      if (FeatureOptions.foptBool(net, "offline", false)) {
        netSleep(net, pickLatency(net))
        throw ctx.makeError(
          "netsim_offline",
          "Simulated network offline (URL was: \"$url\")",
        )
      }
      if (call <= FeatureOptions.foptInt(net, "errorTimes", 0)) {
        netSleep(net, pickLatency(net))
        throw ctx.makeError("netsim_conn", "Simulated connection error (call $call)")
      }
      if (call <= FeatureOptions.foptInt(net, "failTimes", 0)) {
        netSleep(net, pickLatency(net))
        val status = FeatureOptions.foptInt(net, "failStatus", 503)
        val out = linkedMapOf<String, Any?>()
        out["status"] = status
        out["statusText"] = "Simulated Failure"
        out["body"] = "not-used"
        out["json"] = Supplier<Any?> { null }
        out["headers"] = linkedMapOf<String, Any?>()
        out
      } else {
        netSleep(net, pickLatency(net))
        inner(ctx, url, fetchdef)
      }
    }
  }

  private fun pickLatency(net: MutableMap<String, Any?>): Int {
    val l = net["latency"]
    if (l == null) {
      return 0
    }
    if (l is MutableMap<*, *>) {
      val lm = l as MutableMap<String, Any?>
      val min = FeatureOptions.foptInt(lm, "min", 0)
      val max = FeatureOptions.foptInt(lm, "max", min)
      if (max <= min) {
        return min
      }
      return min + ((max - min) shr 1)
    }
    val fixed = FeatureOptions.foptInt(net, "latency", 0)
    return if (fixed < 0) 0 else fixed
  }

  private fun netSleep(net: MutableMap<String, Any?>, ms: Int) {
    if (ms <= 0) {
      return
    }
    FeatureOptions.foptSleep(net).accept(ms)
  }

  private fun buildArgs(ctx: Context, op: Operation, args: MutableMap<String, Any?>?): Any? {
    val opname = op.name

    // Pick the entity's own endpoint from config, not a cross-reference from
    // another resource that also returns it — the same rule makePoint falls
    // back to, so the seed-data query is built from the endpoint the request
    // will actually be sent to: a terminal `{id}` marks a record route, and
    // failing that the shallower path wins.
    val points = Struct.getpath(
      ctx.config,
      listOf("entity", if (ctx.entity == null) "" else ctx.entity!!.name, "op", opname, "points"),
    )
    var point = Struct.getelem(points, 0)
    if (points is List<*>) {
      fun pointPartsLen(p: Any?): Int {
        val parts = Struct.getprop(p, "parts")
        return if (parts is List<*>) parts.size else 0
      }
      fun pointTerminalParam(p: Any?): Boolean {
        val parts = Struct.getprop(p, "parts")
        if (parts !is List<*> || parts.isEmpty()) {
          return false
        }
        val last = parts[parts.size - 1]
        return last is String && last.startsWith("{")
      }
      for (cand in points) {
        val candTerm = pointTerminalParam(cand)
        val bestTerm = pointTerminalParam(point)
        if (candTerm != bestTerm) {
          if (candTerm) {
            point = cand
          }
        } else if (pointPartsLen(cand) < pointPartsLen(point)) {
          point = cand
        }
      }
    }

    // Get required params.
    val paramsPath = Struct.getpath(point, listOf("args", "params"))
    val reqdParams = Struct.select(paramsPath, Struct.jm("reqd", true))
    val reqd = Struct.transform(reqdParams, Struct.jt("`\$EACH`", "", "`\$KEY.name`"))

    val qand = Struct.jt()
    val q = Struct.jm("`\$AND`", qand)

    if (args != null) {
      for (key in Struct.keysof(args)) {
        val isId = "id" == key
        val selected = Struct.select(reqd, key)
        val isReqd = !Struct.isempty(selected)

        if (isId || isReqd) {
          val v = ctx.utility!!.param(ctx, key)
          val ka = Struct.getprop(op.alias, key)

          val qor = Struct.jt(Struct.jm(key, v))
          if (ka is String) {
            qor.add(Struct.jm(ka, v))
          }

          qand.add(Struct.jm("`\$OR`", qor))
        }
      }
    }

    if (ctx.ctrl.explain != null) {
      ctx.ctrl.explain!!["test"] = Struct.jm("query", q)
    }

    return q
  }
}
