package SCALAPACKAGE.utility

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object PreparePath {
  def preparePath(ctx: Context): String = {
    var parts: JList[Object] = null
    Struct.getprop(ctx.point, "parts") match { case l: JList[_] => parts = l.asInstanceOf[JList[Object]]; case _ => }
    if (parts == null) parts = new ArrayList[Object]()
    Struct.join(parts, "/", true)
  }
}

object PrepareMethod {
  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  def prepareMethod(ctx: Context): String = Struct.getprop(ctx.point, "method") match {
    case s: String if s.nonEmpty => s.toUpperCase(java.util.Locale.ROOT)
    case _ => ctx.op.name match {
      case "create" => "POST"
      case "update" => "PUT"
      case "load" => "GET"
      case "list" => "GET"
      case "remove" => "DELETE"
      case "patch" => "PATCH"
      // No GET catch-all: an unrecognised op must fall through to the
      // allow.method gate, not be silently issued as a GET.
      case _ => ""
    }
  }
}

object PrepareParams {
  def prepareParams(ctx: Context): JMap[String, Object] = {
    val utility = ctx.utility
    val point = ctx.point

    var params: JList[Object] = null
    val argsMap = Helpers.toMapAny(Struct.getprop(point, "args"))
    if (argsMap != null) {
      Struct.getprop(argsMap, "params") match { case l: JList[_] => params = l.asInstanceOf[JList[Object]]; case _ => }
    }
    if (params == null) params = new ArrayList[Object]()

    val out = new LinkedHashMap[String, Object]()
    val it = params.iterator()
    while (it.hasNext) {
      val pd = it.next()
      val v = utility.param(ctx, pd)
      if (v != null) {
        val pdm = Helpers.toMapAny(pd)
        if (pdm != null) {
          Struct.getprop(pdm, "name") match { case name: String if name != "" => out.put(name, v); case _ => }
        }
      }
    }
    out
  }
}

object PrepareQuery {
  def prepareQuery(ctx: Context): JMap[String, Object] = {
    val point = ctx.point
    var reqmatch = ctx.reqmatch
    if (reqmatch == null) reqmatch = new LinkedHashMap[String, Object]()

    val params: JList[Object] = new ArrayList[Object]()
    if (point != null) {
      Struct.getprop(point, "params") match { case l: JList[_] => params.addAll(l.asInstanceOf[JList[Object]]); case _ => }
      // A path parameter travels in the path. The generated config lists them
      // as args.params, which prepareParams reads; params is the older list.
      Struct.getpath(point, java.util.List.of("args", "params")) match {
        case l: JList[_] =>
          val pit = l.iterator()
          while (pit.hasNext) {
            Struct.getprop(pit.next(), "name") match { case s: String => params.add(s); case _ => }
          }
        case _ =>
      }
      // A header or cookie name leaves the query unless a query parameter shares it: then both are sent.
      val declared = new ArrayList[Object]()
      Struct.getpath(point, java.util.List.of("args", "query")) match {
        case l: JList[_] => val dit = l.iterator(); while (dit.hasNext) declared.add(Struct.getprop(dit.next(), "name"))
        case _ =>
      }
      for (located <- Seq(Struct.getpath(point, java.util.List.of("args", "header")),
        Struct.getpath(point, java.util.List.of("args", "cookie")))) located match {
        case l: JList[_] =>
          val hit = l.iterator()
          while (hit.hasNext) {
            Struct.getprop(hit.next(), "name") match { case s: String if !declared.contains(s) => params.add(s); case _ => }
          }
        case _ =>
      }
    }

    // A query parameter travels under the name the definition gives it, its
    // orig, which the model may have renamed for the caller.
    val wire = new LinkedHashMap[String, String]()
    if (point != null) {
      Struct.getpath(point, java.util.List.of("args", "query")) match {
        case l: JList[_] =>
          val qit = l.iterator()
          while (qit.hasNext) {
            val qd = qit.next()
            (Struct.getprop(qd, "name"), Struct.getprop(qd, "orig")) match {
              case (n: String, o: String) if o.nonEmpty => wire.put(n, o)
              case _ =>
            }
          }
        case _ =>
      }
    }

    val out = new LinkedHashMap[String, Object]()
    val it = Struct.items(reqmatch).iterator()
    while (it.hasNext) {
      val item = it.next()
      val key = item.get(0) match { case s: String => s; case _ => "" }
      val v = item.get(1)
      if (v != null && "$action" != key && !containsStr(params, key)) out.put(wire.getOrDefault(key, key), v)
    }

    // A create or update passes its query arguments in its data.
    for ((name, orig, v) <- Param.callArgs(ctx, "query") if v != null && !containsStr(params, name)) {
      out.put(orig, v)
    }
    out
  }

  private def containsStr(list: JList[Object], s: String): Boolean = {
    val it = list.iterator()
    while (it.hasNext) {
      it.next() match { case v: String if v == s => return true; case _ => }
    }
    false
  }
}

object PrepareHeaders {
  def prepareHeaders(ctx: Context): JMap[String, Object] = {
    val options = ctx.client.optionsMap()
    val headers = Struct.getprop(options, "headers")
    val cloned = if (headers == null) null else Helpers.toMapAny(Struct.clone(headers))
    val out: JMap[String, Object] = Media.headers(ctx.point,
      if (cloned != null) cloned else new LinkedHashMap[String, Object]())

    // A header argument replaces a default of the same name, whatever its case.
    for ((_, wire, v) <- Param.callArgs(ctx, "header") if v != null) {
      val key = wire.toLowerCase(java.util.Locale.ROOT)
      out.keySet().removeIf(k => k != null && k.toLowerCase(java.util.Locale.ROOT) == key)
      out.put(key, Struct.stringify(v))
    }

    // A cookie argument travels in the cookie header, form serialized and
    // percent-encoded, replacing a cookie of the same name among those the
    // caller's headers already send.
    val sent = Param.callArgs(ctx, "cookie").filter { case (_, _, v) => v != null }
    if (sent.nonEmpty) {
      val names = sent.flatMap { case (_, wire, v) =>
        v match {
          case m: JMap[_, _] => Struct.keysof(m).toArray(Array.empty[String]).toSeq.map(k => Struct.escurl(k))
          case _ => Seq(wire)
        }
      }
      val kept = scala.collection.mutable.ArrayBuffer[String]()
      val it = out.entrySet().iterator()
      while (it.hasNext) {
        val e = it.next()
        if (e.getKey != null && "cookie" == e.getKey.toLowerCase(java.util.Locale.ROOT)) {
          e.getValue match {
            case s: String => kept ++= cookieKeep(s, names)
            case _ =>
          }
          it.remove()
        }
      }
      sent.foreach { case (_, wire, v) =>
        val pair = cookiePair(wire, v)
        if (pair.nonEmpty) kept += pair
      }
      if (kept.nonEmpty) out.put("cookie", kept.mkString("; "))
    }

    out
  }

  // The caller's cookie pieces with the named cookies removed: a cookie is one
  // ;-delimited piece, whatever its value holds.
  def cookieKeep(header: String, names: Seq[String]): scala.collection.mutable.ArrayBuffer[String] = {
    val kept = scala.collection.mutable.ArrayBuffer[String]()
    header.split(";").foreach { piece =>
      val cookie = piece.trim
      if (cookie.nonEmpty && !names.contains(cookie.split("=", 2)(0).trim)) kept += cookie
    }
    kept
  }

  // The form style of a cookie parameter: a list repeats the name, a map sends
  // its own keys, and every value is percent-encoded.
  private def cookiePair(wire: String, v: Object): String = {
    def esc(x: Object): String = Struct.escurl(Struct.stringify(x))
    val pairs = scala.collection.mutable.ArrayBuffer[String]()
    v match {
      case l: JList[_] =>
        val it = l.iterator()
        while (it.hasNext) pairs += wire + "=" + esc(it.next().asInstanceOf[Object])
      case m: JMap[_, _] =>
        val keys = Struct.keysof(m).iterator()
        while (keys.hasNext) {
          val k = keys.next()
          pairs += Struct.escurl(k) + "=" + esc(Struct.getprop(m, k))
        }
      case _ => pairs += wire + "=" + esc(v)
    }
    pairs.mkString("; ")
  }
}

object PrepareBody {
  def prepareBody(ctx: Context): Object =
    if ("data" != ctx.op.input) null
    else if (Media.isRawRequest(ctx.point)) Media.rawBody(ctx.reqdata)
    else ctx.utility.transformRequest(ctx)
}

// NO `object PrepareAuth` HERE, and its absence is the point.
//
// WHERE the credential goes is a fact about the API - header, query or
// cookie, under the name the spec gives - and apidef resolves all of it
// into main.kit.info.security. This file can hold only ONE answer, so the
// object that used to sit here hardcoded `val HEADER_AUTH = "authorization"`
// and an apiKey-in-query API (joplin's `?token=`) got a header it ignores.
//
// So prepareAuth is GENERATED, into utility/PrepareAuth.scala beside this
// file, by src/cmp/scala/PrepareAuth_scala.ts - which emits the one branch
// this API actually uses. It stays `object PrepareAuth` in this same
// package, so utility/Register.scala's `u.prepareAuth = (ctx) =>
// PrepareAuth.prepareAuth(ctx)` binds it with no change: scala resolves the
// object by package, not by file name.
//
// The six objects above are placement-independent and stay templated.
