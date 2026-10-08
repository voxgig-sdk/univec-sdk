package KOTLINPACKAGE.core

import java.util.function.Supplier

import KOTLINPACKAGE.utility.struct.Struct

/** A transport-level response (thin wrapper over the fetcher's map shape). */
@Suppress("UNCHECKED_CAST")
class Response(resmap: Map<String, Any?>?) {

  var status: Int = -1
  var statusText: String = ""
  var headers: Any? = null
  var jsonFunc: Supplier<Any?>? = null
  var body: Any? = null
  var err: RuntimeException? = null

  // Set by a transport that could not read a non-blank body as JSON.
  var unreadable: Boolean = false

  init {
    val s = Struct.getprop(resmap, "status")
    if (s is Number) {
      this.status = Helpers.toInt(s)
    }

    val st = Struct.getprop(resmap, "statusText")
    if (st is String) {
      this.statusText = st
    }

    this.headers = Struct.getprop(resmap, "headers", null)

    val jf = Struct.getprop(resmap, "json")
    if (jf is Supplier<*>) {
      this.jsonFunc = jf as Supplier<Any?>
    }

    this.body = Struct.getprop(resmap, "body", null)

    val e = Struct.getprop(resmap, "err")
    if (e is RuntimeException) {
      this.err = e
    }

    this.unreadable = true == Struct.getprop(resmap, "unreadable")
  }

  companion object {
    private const val PREVIEW_LENGTH = 160

    /**
     * A body that is not JSON. An HTTP failure keeps its own error, with the
     * response described; otherwise the code tells a wrong content type from
     * malformed JSON.
     */
    fun unreadableBody(
      ctx: Context,
      status: Int,
      headers: Any?,
      text: Any?,
      sent: Any?,
      failed: RuntimeException?,
    ): RuntimeException {
      val type = headerValue(headers, "content-type")
      val agent = clean(ctx, headerValue(sent, "user-agent")).ifEmpty { "transport default" }
      val detail = "HTTP " + status + ", content-type " + type.ifEmpty { "none" } +
        ", user-agent " + agent + (if (text == null) "" else ", body: " + preview(ctx, text))

      if (failed != null) {
        if (failed is SdkError) {
          failed.msg += " ($detail)"
          return failed
        }
        return RuntimeException(failed.message + " ($detail)", failed)
      }

      if (type.isEmpty() || type.lowercase().contains("json")) {
        return ctx.makeError("response_json_invalid", "response: body is not valid JSON ($detail)")
      }
      return ctx.makeError("response_content_type", "response: expected JSON, got $type ($detail)")
    }

    private fun headerValue(headers: Any?, name: String): String {
      if (headers !is Map<*, *>) {
        return ""
      }
      for ((k, v) in headers) {
        if (name.equals(k.toString(), ignoreCase = true)) {
          return v.toString()
        }
      }
      return ""
    }

    private fun clean(ctx: Context, s: String): String =
      ctx.utility?.clean?.invoke(ctx, s)?.toString() ?: s

    // Cleaned whole: a secret the bound would split could leave its prefix.
    private fun preview(ctx: Context, text: Any): String {
      val flat = clean(ctx, text.toString().replace(Regex("\\s+"), " ").trim())
      if (flat.codePointCount(0, flat.length) <= PREVIEW_LENGTH) {
        return flat
      }
      return flat.substring(0, flat.offsetByCodePoints(0, PREVIEW_LENGTH)) + "..."
    }
  }
}
