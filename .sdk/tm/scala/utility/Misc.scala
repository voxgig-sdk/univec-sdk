package SCALAPACKAGE.utility

import java.io.{PrintWriter, StringWriter}
import java.nio.charset.StandardCharsets
import java.util.{ArrayList, Base64, IdentityHashMap, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object MakeContext {
  def makeContext(ctxmap: JMap[String, Object], basectx: Context): Context =
    new Context(ctxmap, basectx)
}

// The derived clean block: built by makeOptions from the raw input, grown by
// cleanAdd for as long as the client lives (features register later).
final class CleanConfig(
  val active: Boolean,
  val keys: List[String],
  val values: ArrayList[String],
  val mask: String,
  val hint: Int,
  val min: Int,
) {
  // The options map this sits in can itself be printed; the registry never is.
  override def toString: String = "CleanConfig(active=" + active + ")"
}

// Everything that leaves the pipeline passes through clean; inside it data
// stays raw, so a hook can still read the header it must add to. See
// docs/explanation/secret-redaction.md.
object Clean {
  private val MAXDEPTH = 32
  private val CIRCULAR = "[circular]"
  private val DROP = new Object()
  private val SPLIT_RE = "\\s*,\\s*"

  private def normkey(key: Object): String =
    String.valueOf(key).toLowerCase.replace("-", "").replace("_", "")

  private def splitkeys(keys: Object): List[String] =
    (if (keys == null) "" else String.valueOf(keys)).split(SPLIT_RE).toList
      .map(k => normkey(k)).filter(k => "" != k)

  def splitvalues(values: Object): List[String] = values match {
    case null => Nil
    case l: JList[_] => l.asInstanceOf[JList[Object]].toArray.toList.collect { case s: String => s }
    case v => String.valueOf(v).split(SPLIT_RE).toList.filter(s => "" != s)
  }

  private def count(v: Object, dflt: Int): Int = {
    val n: Double = v match {
      case n: java.lang.Number => n.doubleValue()
      case s: String =>
        try s.trim.toDouble
        catch { case _: NumberFormatException => return dflt }
      case _ => return dflt
    }
    if (n.isNaN || n.isInfinite || n < 0) dflt else Math.floor(n).toInt
  }

  def makeCleanConfig(cleanopts: Object): CleanConfig = {
    val opts = Helpers.toMapAny(cleanopts)
    def get(k: String): Object = if (opts == null) null else opts.get(k)
    new CleanConfig(
      java.lang.Boolean.FALSE != get("active"),
      splitkeys(get("keys")),
      new ArrayList[String](),
      get("mask") match { case s: String => s; case _ => "[redacted]" },
      count(get("hint"), 0),
      Math.max(1, count(get("min"), 4)),
    )
  }

  // A context without options (makeError accepts a bare one) still masks by
  // the schema defaults.
  private def cleanConfig(ctx: Context): CleanConfig = {
    if (ctx != null && ctx.options != null) {
      val derived = Helpers.toMapAny(ctx.options.get("__derived__"))
      if (derived != null) derived.get("clean") match {
        case c: CleanConfig => return c
        case _ =>
      }
    }
    makeCleanConfig(Schema.optspec.get("clean"))
  }

  // encodeURIComponent, byte for byte: URLEncoder differs on space and `~!'()*`.
  private def percentEncode(value: String): String = {
    val out = new StringBuilder()
    for (b <- value.getBytes(StandardCharsets.UTF_8)) {
      val c = b & 0xff
      val ch = c.toChar
      if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
          "-_.!~*'()".indexOf(ch) >= 0) out.append(ch)
      else out.append('%').append(String.format("%02X", java.lang.Integer.valueOf(c)))
    }
    out.toString
  }

  // The encoded forms a value travels in.
  private def forms(value: String): List[String] = {
    val out = new ArrayList[String]()
    out.add(value)
    def add(s: String): Unit = if ("" != s && !out.contains(s)) out.add(s)
    try add(Base64.getEncoder.encodeToString(value.getBytes(StandardCharsets.UTF_8)))
    catch { case _: RuntimeException => }
    try add(percentEncode(value))
    catch { case _: RuntimeException => }
    try {
      val j = Struct.jsonify(value)
      if (j.length >= 2) add(j.substring(1, j.length - 1))
    }
    catch { case _: RuntimeException => }
    out.toArray(new Array[String](0)).toList
  }

  private[utility] def registerValue(cfg: CleanConfig, value: Object): Unit = value match {
    case s: String if s.length >= cfg.min =>
      cfg.synchronized {
        var changed = false
        for (form <- forms(s)) {
          if (form.length >= cfg.min && !cfg.values.contains(form)) {
            cfg.values.add(form)
            changed = true
          }
        }
        if (changed) cfg.values.sort(new java.util.Comparator[String] {
          def compare(a: String, b: String): Int = Integer.compare(b.length, a.length)
        })
      }
    case _ =>
  }

  def cleanAdd(ctx: Context, value: Object): Unit = registerValue(cleanConfig(ctx), value)

  private def maskValue(cfg: CleanConfig, value: String): String =
    if (0 < cfg.hint && value.length > 2 * cfg.hint) cfg.mask + value.substring(value.length - cfg.hint)
    else cfg.mask

  private def cleanString(cfg: CleanConfig, text: String): String = {
    val values = cfg.synchronized { new ArrayList[String](cfg.values) }
    var out = text
    val it = values.iterator()
    while (it.hasNext) {
      val v = it.next()
      if (out.contains(v)) out = out.replace(v, maskValue(cfg, v))
    }
    out
  }

  private def sensitiveKey(cfg: CleanConfig, key: Object): Boolean = {
    if (key == null || key.isInstanceOf[java.lang.Number]) return false
    val nk = normkey(key)
    cfg.keys.exists(k => nk.contains(k))
  }

  private def isfunc(v: Object): Boolean = {
    val cls = v.getClass
    cls.isSynthetic || cls.getInterfaces.exists { i =>
      i.getName.startsWith("java.util.function.") || i.getName.startsWith("scala.Function")
    }
  }

  private def stackOf(err: Throwable): String = {
    val sw = new StringWriter()
    err.printStackTrace(new PrintWriter(sw))
    sw.toString
  }

  // The SDK's own objects have no serialisation hook, so this is the record
  // each one leaves as. The context stays raw on the error and is not here.
  private def record(v: Object): JMap[String, Object] = {
    val out = new LinkedHashMap[String, Object]()
    v match {
      case e: Throwable =>
        out.put("message", if (e.getMessage == null) "" else e.getMessage)
        out.put("stack", stackOf(e))
        e match {
          case se: SdkError =>
            out.put("sdk", se.sdk)
            out.put("code", se.code)
            out.put("status", java.lang.Integer.valueOf(se.status))
            out.put("result", se.result)
            out.put("spec", se.spec)
          case _ =>
        }
      case s: Spec =>
        out.put("method", s.method)
        out.put("base", s.base)
        out.put("prefix", s.prefix)
        out.put("suffix", s.suffix)
        out.put("path", s.path)
        out.put("url", s.url)
        out.put("params", s.params)
        out.put("query", s.query)
        out.put("headers", s.headers)
        out.put("body", s.body)
        out.put("step", s.step)
      case r: Result =>
        out.put("ok", java.lang.Boolean.valueOf(r.ok))
        out.put("status", java.lang.Integer.valueOf(r.status))
        out.put("statusText", r.statusText)
        out.put("headers", r.headers)
        out.put("body", r.body)
        out.put("resdata", r.resdata)
        out.put("resmatch", r.resmatch)
        out.put("err", r.err)
        out.put("paging", r.paging)
      case r: Response =>
        out.put("status", java.lang.Integer.valueOf(r.status))
        out.put("statusText", r.statusText)
        out.put("headers", r.headers)
        out.put("body", r.body)
        out.put("err", r.err)
      case o: Operation =>
        out.put("entity", o.entity)
        out.put("name", o.name)
        out.put("input", o.input)
      case c: Context =>
        out.put("id", c.id)
        out.put("op", c.op)
        out.put("spec", c.spec)
        out.put("entity", c.entity)
        out.put("result", c.result)
        out.put("response", c.response)
        out.put("meta", c.meta)
      case e: Entity =>
        out.put("name", e.getName())
        out.put("data", try e.data() catch { case _: RuntimeException => null })
      case _ =>
    }
    out
  }

  // A masked plain-data copy: functions dropped, cycles cut, and nothing
  // shared with the live value, whose spec must stay raw.
  private def snapshot(cfg: CleanConfig, v: Object, key: Object, depth: Int,
      seen: IdentityHashMap[Object, Object]): Object = {
    if (v == null || (v eq Struct.UNDEF)) return v

    v match {
      case s: String => return if (sensitiveKey(cfg, key)) maskValue(cfg, s) else cleanString(cfg, s)
      case _ =>
    }

    if (isfunc(v)) return DROP

    v match {
      case _: java.lang.Number | _: java.lang.Boolean | _: java.lang.Character =>
        return if (sensitiveKey(cfg, key)) cfg.mask else v
      case _ =>
    }

    if (MAXDEPTH <= depth || seen.containsKey(v)) return CIRCULAR

    if (sensitiveKey(cfg, key)) return cfg.mask

    seen.put(v, v)
    try {
      v match {
        case l: JList[_] =>
          val out = new ArrayList[Object]()
          var i = 0
          val it = l.asInstanceOf[JList[Object]].iterator()
          while (it.hasNext) {
            val s = snapshot(cfg, it.next(), java.lang.Integer.valueOf(i), depth + 1, seen)
            if (s ne DROP) out.add(s)
            i += 1
          }
          out
        case m: JMap[_, _] => plain(cfg, m, depth, seen)
        case _: Throwable | _: Spec | _: Result | _: Response | _: Operation | _: Context | _: Entity =>
          plain(cfg, record(v), depth, seen)
        case _ => cleanString(cfg, v.toString)
      }
    }
    finally seen.remove(v)
  }

  private def plain(cfg: CleanConfig, m: JMap[_, _], depth: Int,
      seen: IdentityHashMap[Object, Object]): JMap[String, Object] = {
    val out = new LinkedHashMap[String, Object]()
    val it = m.asInstanceOf[JMap[Object, Object]].entrySet().iterator()
    while (it.hasNext) {
      val e = it.next()
      val s = snapshot(cfg, e.getValue, e.getKey, depth + 1, seen)
      if (s ne DROP) out.put(cleanName(cfg, out, String.valueOf(e.getKey)), s)
    }
    out
  }

  // A registered value used as a map key is masked like any other string;
  // keys that mask alike take a counter, so none is lost.
  private def cleanName(cfg: CleanConfig, out: JMap[String, Object], key: String): String = {
    val name = cleanString(cfg, key)
    if (name == key || !out.containsKey(name)) return name
    var i = 1
    while (out.containsKey(name + "#" + i)) i += 1
    name + "#" + i
  }

  private[utility] def cleanWith(cfg: CleanConfig, value: Object): Object = {
    if (!cfg.active) return value

    value match {
      case s: String => return cleanString(cfg, s)
      case err: SdkError =>
        // Cleaned in place, since it is about to be thrown.
        err.msg = cleanString(cfg, err.msg)
        err.code = cleanString(cfg, err.code)
        err.result = snapshot(cfg, err.result, "result", 1, new IdentityHashMap[Object, Object]())
        err.spec = snapshot(cfg, err.spec, "spec", 1, new IdentityHashMap[Object, Object]())
        return err
      // A throwable's message is fixed, so a foreign one leaves as a cleaned
      // copy of the SDK's own error, without the raw one as its cause.
      case t: Throwable =>
        return new SdkError("", cleanString(cfg, if (t.getMessage == null) String.valueOf(t) else t.getMessage), null)
      case _ =>
    }

    val out = snapshot(cfg, value, null, 0, new IdentityHashMap[Object, Object]())
    if (out eq DROP) null else out
  }

  def clean(ctx: Context, v: Object): Object = cleanWith(cleanConfig(ctx), v)

  def cleanKey(ctx: Context, key: Object): Boolean = sensitiveKey(cleanConfig(ctx), key)

  // Every scalar under a sensitive name, at any depth and of any shape: a
  // credential mistyped as a map or a number is still a credential, and a
  // message about it can quote it.
  private[utility] def addSensitiveWith(cfg: CleanConfig, v: Object): Unit =
    addSensitive(cfg, v, false, 0, new IdentityHashMap[Object, Object]())

  private def addSensitive(cfg: CleanConfig, v: Object, under: Boolean, depth: Int,
      seen: IdentityHashMap[Object, Object]): Unit = {
    if (v == null || MAXDEPTH <= depth) return
    v match {
      case s: String => if (under) registerValue(cfg, s)
      case n: java.lang.Number => if (under) registerValue(cfg, Struct.stringify(n))
      case _ if seen.containsKey(v) =>
      case m: JMap[_, _] =>
        seen.put(v, v)
        val it = m.asInstanceOf[JMap[Object, Object]].entrySet().iterator()
        while (it.hasNext) {
          val e = it.next()
          addSensitive(cfg, e.getValue, under || sensitiveKey(cfg, e.getKey), depth + 1, seen)
        }
      case l: JList[_] =>
        seen.put(v, v)
        val it = l.asInstanceOf[JList[Object]].iterator()
        while (it.hasNext) addSensitive(cfg, it.next(), under, depth + 1, seen)
      case _ =>
    }
  }

  // The caller holds the explain map, so the cleaned copy is written back
  // into it rather than swapped for it.
  private[utility] def cleanExplain(ctx: Context): Unit = {
    val explain = ctx.ctrl.explain
    if (explain == null) return
    val cleaned = Helpers.toMapAny(clean(ctx, explain))
    if (cleaned != null && (cleaned ne explain)) {
      explain.clear()
      explain.putAll(cleaned)
    }
  }
}

object Done {
  def done(ctx: Context): Object = {
    if (ctx.ctrl.explain != null) {
      Clean.cleanExplain(ctx)
      val rm = Helpers.toMapAny(ctx.ctrl.explain.get("result"))
      if (rm != null) rm.remove("err")
    }

    if (ctx.result != null && ctx.result.ok) return ctx.result.resdata

    MakeError.makeError(ctx, null)
  }
}

object Param {
  def param(ctx: Context, paramdef: Object): Object = {
    val pt = Struct.typify(paramdef)

    val key: String =
      if (0 < (Struct.T_string & pt)) paramdef match { case s: String => s; case _ => "" }
      else Struct.getprop(paramdef, "name") match { case s: String => s; case _ => "" }

    val akey = alias(ctx.point, key)
    if (ctx.spec != null && "" != akey &&
      Struct.getprop(ctx.reqmatch, key, null) == null && Struct.getprop(ctx.matchData, key, null) == null) {
      ctx.spec.alias.put(akey, key)
    }

    value(ctx, ctx.point, key)
  }

  // The name a point gives a parameter in the call, if it renames it.
  private def alias(point: Object, key: String): String = {
    if (point == null) return ""
    val aliasMap = Helpers.toMapAny(Struct.getprop(point, "alias"))
    if (aliasMap == null) return ""
    Struct.getprop(aliasMap, key) match { case ak: String => ak; case _ => "" }
  }

  // The value the call or its entity gives a point's parameter, under its
  // name or the point's alias for it.
  def value(ctx: Context, point: Object, key: String): Object = {
    val akey = alias(point, key)

    var v = Struct.getprop(ctx.reqmatch, key, null)
    if (v == null) v = Struct.getprop(ctx.matchData, key, null)
    if (v == null && "" != akey) v = Struct.getprop(ctx.reqmatch, akey, null)
    if (v == null) v = Struct.getprop(ctx.reqdata, key, null)
    if (v == null) v = Struct.getprop(ctx.data, key, null)
    if (v == null && "" != akey) {
      v = Struct.getprop(ctx.reqdata, akey, null)
      if (v == null) v = Struct.getprop(ctx.data, akey, null)
    }
    v
  }

  // The arguments a point declares in one location, query or header, each as
  // (name, wire, value): the name it travels under and the value this call
  // passes in its match or else its data. Unlike a path parameter, the
  // entity's stored match and data never supply one.
  def callArgs(ctx: Context, kind: String): Seq[(String, String, Object)] = {
    if (ctx.point == null) return Seq.empty
    Struct.getpath(ctx.point, java.util.List.of("args", kind)) match {
      case l: JList[_] =>
        val out = scala.collection.mutable.ArrayBuffer[(String, String, Object)]()
        val it = l.iterator()
        while (it.hasNext) {
          val ad = it.next()
          Struct.getprop(ad, "name") match {
            case name: String if name.nonEmpty =>
              val wire = Struct.getprop(ad, "orig") match {
                case o: String if o.nonEmpty => o
                case _ => name
              }
              var v: Object = if (ctx.reqmatch == null) null else Struct.getprop(ctx.reqmatch, name, null)
              if (v == null && ctx.reqdata != null) v = Struct.getprop(ctx.reqdata, name, null)
              out += ((name, wire, v))
            case _ =>
          }
        }
        out.toSeq
      case _ => Seq.empty
    }
  }
}
