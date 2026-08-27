package KOTLINPACKAGE.feature

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

// Client-side role/permission enforcement. Before an operation resolves its
// endpoint, the required permission for that entity+operation is checked
// against the permissions the client holds; a disallowed call is
// short-circuited with an `rbac_denied` error (via ctx.out["point"], which
// makePoint surfaces) and never touches the network.
class RbacFeature : BaseFeature("rbac", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var granted: MutableMap<String, Boolean> = linkedMapOf()

  // Activity tracking (mirrors the ts client._rbac record).
  var allowed = 0
  var denied = 0
  var last: MutableMap<String, Any?>? = null

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    this.granted = linkedMapOf()
    val permissions = FeatureOptions.foptStrList(this.options, "permissions")
    if (permissions != null) {
      for (p in permissions) {
        this.granted[p] = true
      }
    }
  }

  override fun prePoint(ctx: Context) {
    if (!this.active) {
      return
    }

    val required = required(ctx)
    if (required == null) {
      // No rule: honour the default policy.
      if (FeatureOptions.foptBool(this.options, "deny", false)) {
        reject(ctx, "<default-deny>")
      }
      return
    }

    if (this.granted["*"] == true || this.granted[required] == true) {
      track(ctx, required, true)
      return
    }

    reject(ctx, required)
  }

  private fun required(ctx: Context): String? {
    val rules = FeatureOptions.foptMap(this.options, "rules") ?: return null

    val entity = if (ctx.entity != null) ctx.entity!!.name else ctx.op.entity
    val opname = ctx.op.name

    for (key in arrayOf("$entity.$opname", opname, "*")) {
      val r = rules[key]
      if (r is String) {
        return r
      }
    }
    return null
  }

  private fun reject(ctx: Context, required: String) {
    track(ctx, required, false)

    val opname = ctx.op.name
    val err = ctx.makeError(
      "rbac_denied",
      "Permission \"" + required + "\" required for operation \"" + opname + "\"",
    )

    // Short-circuit endpoint resolution; makePoint surfaces this error
    // before any network activity.
    ctx.out["point"] = err
  }

  private fun track(ctx: Context, required: String, wasAllowed: Boolean) {
    if (wasAllowed) {
      this.allowed++
    } else {
      this.denied++
    }
    val opname = ctx.op.name
    val rec = linkedMapOf<String, Any?>()
    rec["required"] = required
    rec["allowed"] = wasAllowed
    rec["op"] = opname
    this.last = rec
  }
}
