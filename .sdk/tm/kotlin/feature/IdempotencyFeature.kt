package KOTLINPACKAGE.feature

import java.util.concurrent.ThreadLocalRandom
import java.util.function.Supplier

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

// Idempotency keys for mutating operations. Adds an `Idempotency-Key` header
// (name configurable via `header`) to unsafe requests so a server can
// de-duplicate retried writes. Set once, at PreRequest. A caller-supplied
// header is never overwritten (case-insensitive). The key generator is
// injectable (`keygen`).
@Suppress("UNCHECKED_CAST")
class IdempotencyFeature : BaseFeature("idempotency", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._idempotency record).
  var issued = 0
  var last = ""

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override fun preRequest(ctx: Context) {
    if (!this.active) {
      return
    }

    val spec = ctx.spec ?: return

    if (!mutating(ctx)) {
      return
    }

    val header = FeatureOptions.foptStr(this.options, "header", "Idempotency-Key")

    // Respect a key the caller already provided.
    if (FeatureOptions.fheaderHas(spec.headers, header)) {
      return
    }

    val key = genkey()
    spec.headers[header] = key

    this.issued++
    this.last = key
  }

  private fun mutating(ctx: Context): Boolean {
    var methods: List<String>? = FeatureOptions.foptStrList(this.options, "methods")
    if (methods == null) {
      methods = listOf("POST", "PUT", "PATCH", "DELETE")
    }
    var method = ""
    if (ctx.spec != null) {
      method = ctx.spec!!.method.uppercase()
    }
    if ("" != method) {
      for (m in methods) {
        if (m.uppercase() == method) {
          return true
        }
      }
    }

    val opname = ctx.op.name
    var ops: List<String>? = FeatureOptions.foptStrList(this.options, "ops")
    if (ops == null) {
      ops = listOf("create", "update", "remove")
    }
    for (o in ops) {
      if (o == opname) {
        return true
      }
    }
    return false
  }

  private fun genkey(): String {
    val kg = this.options?.get("keygen")
    if (kg is Supplier<*>) {
      return (kg as Supplier<Any?>).get().toString()
    }
    val r = ThreadLocalRandom.current()
    val key = String.format(
      "%06x%06x%06x%06x",
      r.nextInt(0x1000000), r.nextInt(0x1000000),
      r.nextInt(0x1000000), r.nextInt(0x1000000),
    )
    return key.substring(0, 24)
  }
}
