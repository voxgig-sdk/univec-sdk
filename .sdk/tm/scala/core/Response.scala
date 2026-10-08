package SCALAPACKAGE.core

import java.util.{Map => JMap}
import java.util.function.Supplier
import SCALAPACKAGE.utility.struct.Struct

// A transport-level response (thin wrapper over the fetcher's map shape).
class Response(resmap: JMap[String, Object]) {

  var status: Int = -1
  var statusText: String = ""
  var headers: Object = null
  var jsonFunc: Supplier[Object] = null
  var body: Object = null
  var err: RuntimeException = null
  // Set by a transport that could not read a non-blank body as JSON.
  var unreadable: Boolean = false

  locally {
    val s = Struct.getprop(resmap, "status")
    if (s != null) status = Helpers.toInt(s)

    Struct.getprop(resmap, "statusText") match { case st: String => statusText = st; case _ => }

    headers = Struct.getprop(resmap, "headers", null)

    Struct.getprop(resmap, "json") match {
      case jf: Supplier[_] => jsonFunc = jf.asInstanceOf[Supplier[Object]]
      case _ =>
    }

    body = Struct.getprop(resmap, "body", null)

    Struct.getprop(resmap, "err") match {
      case e: RuntimeException => err = e
      case _ =>
    }

    unreadable = java.lang.Boolean.TRUE == Struct.getprop(resmap, "unreadable")
  }
}

object Response {
  private val PreviewLength = 160

  // A body that is not JSON. An HTTP failure keeps its own error, with the
  // response described; otherwise the code tells a wrong content type from
  // malformed JSON.
  def unreadableBody(ctx: Context, status: Int, headers: Object, text: Object, sent: Object,
      failed: RuntimeException): RuntimeException = {
    val ctype = headerValue(headers, "content-type")
    val agent = clean(ctx, headerValue(sent, "user-agent"))
    val detail = "HTTP " + status + ", content-type " + (if (ctype.isEmpty) "none" else ctype) +
      ", user-agent " + (if (agent.isEmpty) "transport default" else agent) +
      (if (text == null) "" else ", body: " + preview(ctx, text))

    failed match {
      case null if ctype.isEmpty || ctype.toLowerCase.contains("json") =>
        ctx.makeError("response_json_invalid", "response: body is not valid JSON (" + detail + ")")
      case null =>
        ctx.makeError("response_content_type",
          "response: expected JSON, got " + ctype + " (" + detail + ")")
      case e: SdkError =>
        e.msg += " (" + detail + ")"
        e
      case e =>
        new RuntimeException(e.getMessage + " (" + detail + ")", e)
    }
  }

  private def headerValue(headers: Object, name: String): String = headers match {
    case hm: JMap[_, _] =>
      val it = hm.entrySet().iterator()
      while (it.hasNext) {
        val e = it.next()
        if (name.equalsIgnoreCase(String.valueOf(e.getKey))) return String.valueOf(e.getValue)
      }
      ""
    case _ => ""
  }

  private def clean(ctx: Context, s: String): String =
    if (ctx.utility == null || ctx.utility.clean == null) s
    else String.valueOf(ctx.utility.clean(ctx, s))

  // Cleaned whole: a secret the bound would split could leave its prefix.
  private def preview(ctx: Context, text: Object): String = {
    val flat = clean(ctx, String.valueOf(text).replaceAll("\\s+", " ").trim)
    if (flat.codePointCount(0, flat.length) <= PreviewLength) flat
    else flat.substring(0, flat.offsetByCodePoints(0, PreviewLength)) + "..."
  }
}
