package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, Helpers, SdkClient}

// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status and
// timing — on the feature's entries. Sensitive header values (matching
// `redact`, default authorization/cookie/api-key style names) are masked.
// An optional `onEntry` callback receives each finished entry (e.g. to
// stream to a console). `max` caps the buffer (default 100).
class DebugFeature extends BaseFeature("debug", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  // Activity tracking (mirrors the ts client._debug record).
  var entries: JList[JMap[String, Object]] = new ArrayList[JMap[String, Object]]()

  private val DEBUG_ENTRY_KEY = "debug_entry"

  private val DEFAULT_REDACT: JList[String] = java.util.List.of(
    "authorization", "cookie", "set-cookie", "api-key", "apikey",
    "x-api-key", "idempotency-key")

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override def preRequest(ctx: Context): Unit = {
    if (!this.active) {
      return
    }

    var entity = "_"
    var opname = "_"
    if (ctx.op != null) {
      entity = ctx.op.entity
      opname = ctx.op.name
    }

    val entry = new LinkedHashMap[String, Object]()
    entry.put("op", entity + "." + opname)
    entry.put("start", java.lang.Long.valueOf(FeatureOptions.foptNow(this.options).getAsLong()))
    if (ctx.spec != null) {
      entry.put("method", ctx.spec.method)
      if (!"".equals(ctx.spec.url)) {
        entry.put("url", ctx.spec.url)
      } else {
        entry.put("url", ctx.spec.path)
      }
      entry.put("headers", redact(ctx.spec.headers))
    }
    ctx.out.put(DEBUG_ENTRY_KEY, entry)
  }

  override def preResponse(ctx: Context): Unit = {
    if (!this.active) {
      return
    }

    val entry = Helpers.toMapAny(ctx.out.get(DEBUG_ENTRY_KEY))
    if (entry == null) {
      return
    }
    if (ctx.response != null) {
      entry.put("status", java.lang.Integer.valueOf(ctx.response.status))
      val url = entry.get("url")
      if ((url == null || "".equals(url)) && ctx.spec != null) {
        entry.put("url", ctx.spec.url)
      }
    }
  }

  override def preDone(ctx: Context): Unit = {
    finish(ctx, true)
  }

  override def preUnexpected(ctx: Context): Unit = {
    val entry = Helpers.toMapAny(ctx.out.get(DEBUG_ENTRY_KEY))
    if (entry != null && ctx.ctrl != null && ctx.ctrl.err != null) {
      entry.put("error", ctx.ctrl.err.getMessage)
    }
    finish(ctx, false)
  }

  private def finish(ctx: Context, ok: Boolean): Unit = {
    // Finish once per operation: the marker in ctx.out is consumed here.
    val entry = Helpers.toMapAny(ctx.out.get(DEBUG_ENTRY_KEY))
    if (entry == null) {
      return
    }
    ctx.out.remove(DEBUG_ENTRY_KEY)

    entry.put("ok", java.lang.Boolean.valueOf(ok && (ctx.result == null || ctx.result.ok)))
    val start = Helpers.toLong(entry.get("start"), 0)
    var dur = FeatureOptions.foptNow(this.options).getAsLong() - start
    if (dur < 0) {
      dur = 0
    }
    entry.put("durationMs", java.lang.Long.valueOf(dur))
    if (entry.get("status") == null && ctx.result != null) {
      entry.put("status", java.lang.Integer.valueOf(ctx.result.status))
    }

    this.entries.add(entry)
    val max = FeatureOptions.foptInt(this.options, "max", 100)
    while (this.entries.size() > max) {
      this.entries.remove(0)
    }

    this.options.get("onEntry") match {
      case c: java.util.function.Consumer[_] =>
        c.asInstanceOf[java.util.function.Consumer[JMap[String, Object]]].accept(entry)
      case _ =>
    }
  }

  private def redact(headers: JMap[String, Object]): JMap[String, Object] = {
    val out = new LinkedHashMap[String, Object]()
    if (headers == null) {
      return out
    }
    var patterns = FeatureOptions.foptStrList(this.options, "redact")
    if (patterns == null) {
      patterns = DEFAULT_REDACT
    }
    val it = headers.entrySet().iterator()
    while (it.hasNext) {
      val h = it.next()
      var masked = false
      val pit = patterns.iterator()
      while (!masked && pit.hasNext) {
        val p = pit.next()
        if (h.getKey.toLowerCase().equals(p)) {
          masked = true
        }
      }
      if (masked) {
        out.put(h.getKey, "<redacted>")
      } else {
        out.put(h.getKey, h.getValue)
      }
    }
    out
  }
}
