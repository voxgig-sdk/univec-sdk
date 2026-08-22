package SCALAPACKAGE.feature

import java.util.{LinkedHashMap, Map => JMap}
import java.util.concurrent.ThreadLocalRandom
import SCALAPACKAGE.core.{Context, SdkClient}

// Idempotency keys for mutating operations. Adds an `Idempotency-Key`
// header (name configurable via `header`) to unsafe requests so a server
// can de-duplicate retried writes. The key is set once, at PreRequest,
// before the request is built — so it is stable across transport-level
// retries of the same call. A caller-supplied header is never overwritten
// (case-insensitive). The key generator is injectable (`keygen`).
class IdempotencyFeature extends BaseFeature("idempotency", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  // Activity tracking (mirrors the ts client._idempotency record).
  var issued: Int = 0
  var last: String = ""

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override def preRequest(ctx: Context): Unit = {
    if (!this.active) {
      return
    }

    val spec = ctx.spec
    if (spec == null) {
      return
    }

    if (!mutating(ctx)) {
      return
    }

    val header = FeatureOptions.foptStr(this.options, "header", "Idempotency-Key")
    if (spec.headers == null) {
      spec.headers = new LinkedHashMap[String, Object]()
    }

    // Respect a key the caller already provided.
    if (FeatureOptions.fheaderHas(spec.headers, header)) {
      return
    }

    val key = genkey()
    spec.headers.put(header, key)

    this.issued += 1
    this.last = key
  }

  private def mutating(ctx: Context): Boolean = {
    var methods = FeatureOptions.foptStrList(this.options, "methods")
    if (methods == null) {
      methods = java.util.List.of("POST", "PUT", "PATCH", "DELETE")
    }
    var method = ""
    if (ctx.spec != null) {
      method = ctx.spec.method.toUpperCase()
    }
    if (!"".equals(method)) {
      val it = methods.iterator()
      while (it.hasNext) {
        if (it.next().toUpperCase().equals(method)) {
          return true
        }
      }
    }

    var opname = ""
    if (ctx.op != null) {
      opname = ctx.op.name
    }
    var ops = FeatureOptions.foptStrList(this.options, "ops")
    if (ops == null) {
      ops = java.util.List.of("create", "update", "remove")
    }
    val oit = ops.iterator()
    while (oit.hasNext) {
      if (oit.next().equals(opname)) {
        return true
      }
    }
    false
  }

  private def genkey(): String = {
    this.options.get("keygen") match {
      case s: java.util.function.Supplier[_] =>
        return String.valueOf(s.asInstanceOf[java.util.function.Supplier[Object]].get())
      case _ =>
    }
    val r = ThreadLocalRandom.current()
    val key = String.format("%06x%06x%06x%06x",
      java.lang.Integer.valueOf(r.nextInt(0x1000000)), java.lang.Integer.valueOf(r.nextInt(0x1000000)),
      java.lang.Integer.valueOf(r.nextInt(0x1000000)), java.lang.Integer.valueOf(r.nextInt(0x1000000)))
    key.substring(0, 24)
  }
}
