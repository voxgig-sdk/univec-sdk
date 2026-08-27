package KOTLINPACKAGE.feature

import java.util.function.Consumer

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.SdkClient

// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status and
// timing. `max` caps the buffer (default 100).
@Suppress("UNCHECKED_CAST")
class DebugFeature : BaseFeature("debug", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._debug record).
  var entries: MutableList<MutableMap<String, Any?>> = mutableListOf()

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override fun preRequest(ctx: Context) {
    if (!this.active) {
      return
    }

    val entity = ctx.op.entity
    val opname = ctx.op.name

    val entry = linkedMapOf<String, Any?>()
    entry["op"] = "$entity.$opname"
    entry["start"] = FeatureOptions.foptNow(this.options).getAsLong()
    val spec = ctx.spec
    if (spec != null) {
      entry["method"] = spec.method
      if ("" != spec.url) {
        entry["url"] = spec.url
      } else {
        entry["url"] = spec.path
      }
      entry["headers"] = redact(spec.headers)
    }
    ctx.out[DEBUG_ENTRY_KEY] = entry
  }

  override fun preResponse(ctx: Context) {
    if (!this.active) {
      return
    }

    val entry = Helpers.toMapAny(ctx.out[DEBUG_ENTRY_KEY]) ?: return
    val response = ctx.response
    if (response != null) {
      entry["status"] = response.status
      val url = entry["url"]
      if ((url == null || "" == url) && ctx.spec != null) {
        entry["url"] = ctx.spec!!.url
      }
    }
  }

  override fun preDone(ctx: Context) {
    finish(ctx, true)
  }

  override fun preUnexpected(ctx: Context) {
    val entry = Helpers.toMapAny(ctx.out[DEBUG_ENTRY_KEY])
    if (entry != null && ctx.ctrl.err != null) {
      entry["error"] = ctx.ctrl.err!!.message
    }
    finish(ctx, false)
  }

  private fun finish(ctx: Context, ok: Boolean) {
    val entry = Helpers.toMapAny(ctx.out[DEBUG_ENTRY_KEY]) ?: return
    ctx.out.remove(DEBUG_ENTRY_KEY)

    val result = ctx.result
    entry["ok"] = ok && (result == null || result.ok)
    val start = Helpers.toLong(entry["start"], 0)
    var dur = FeatureOptions.foptNow(this.options).getAsLong() - start
    if (dur < 0) {
      dur = 0
    }
    entry["durationMs"] = dur
    if (entry["status"] == null && result != null) {
      entry["status"] = result.status
    }

    this.entries.add(entry)
    val max = FeatureOptions.foptInt(this.options, "max", 100)
    while (this.entries.size > max) {
      this.entries.removeAt(0)
    }

    val onEntry = this.options?.get("onEntry")
    if (onEntry is Consumer<*>) {
      (onEntry as Consumer<MutableMap<String, Any?>>).accept(entry)
    }
  }

  private fun redact(headers: MutableMap<String, Any?>?): MutableMap<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    if (headers == null) {
      return out
    }
    var patterns: List<String>? = FeatureOptions.foptStrList(this.options, "redact")
    if (patterns == null) {
      patterns = DEFAULT_REDACT
    }
    for (h in headers.entries) {
      var masked = false
      for (p in patterns) {
        if (h.key.lowercase() == p) {
          masked = true
          break
        }
      }
      if (masked) {
        out[h.key] = "<redacted>"
      } else {
        out[h.key] = h.value
      }
    }
    return out
  }

  companion object {
    private const val DEBUG_ENTRY_KEY = "debug_entry"

    private val DEFAULT_REDACT: List<String> = listOf(
      "authorization", "cookie", "set-cookie", "api-key", "apikey",
      "x-api-key", "idempotency-key",
    )
  }
}
