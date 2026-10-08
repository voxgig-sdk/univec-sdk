package KOTLINPACKAGE.utility

import java.io.InputStream

import KOTLINPACKAGE.utility.struct.Struct

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.
object Media {

  // The data key holding a raw request body. Like `$action`, it can never be
  // a declared argument name.
  const val RAW_BODY = "\$body"

  fun isJsonMedia(media: Any?): Boolean {
    val m = (media as? String ?: "").split(";", limit = 2)[0].trim().lowercase()
    return "application/json" == m || "text/json" == m || m.endsWith("+json")
  }

  // The declared JSON type alone, else every declared type in the model's
  // order; null when no success response declares a body.
  fun acceptOf(point: Any?): String? {
    val res = Struct.getprop(point, "response", null)
    val media = Struct.getprop(res, "media", null) as? String
    if (media.isNullOrEmpty()) return null
    if ("json" == Struct.getprop(res, "kind", null)) return media
    val types = mutableListOf(media)
    val alts = Struct.getprop(res, "alternatives", null)
    if (alts is List<*>) {
      for (alt in alts) {
        val m = Struct.getprop(alt, "media", null) as? String
        if (!m.isNullOrEmpty()) types.add(m)
      }
    }
    return types.joinToString(", ")
  }

  fun isRawRequest(point: Any?): Boolean =
    "raw" == Struct.getprop(Struct.getprop(point, "body", null), "kind", null)

  fun isJsonRequest(point: Any?): Boolean =
    "json" == Struct.getprop(Struct.getprop(point, "body", null), "kind", null)

  // Bytes or a stream go as given. A map or a list is JSON, and so is a scalar
  // on a point that declares a JSON body.
  fun requestBody(point: Any?, body: Any): Any = when {
    body is ByteArray || body is InputStream -> body
    Struct.isnode(body) || isJsonRequest(point) -> Struct.jsonify(body)
    else -> body
  }

  private fun hasHeader(headers: Map<String, Any?>, name: String): Boolean =
    headers.keys.any { it.lowercase() == name }

  // A caller's accept wins. A declared request type replaces each JSON
  // content-type, the SDK default, and leaves any other the caller set.
  fun headers(point: Any?, headers: MutableMap<String, Any?>): MutableMap<String, Any?> {
    val accept = acceptOf(point)
    if (accept != null && !hasHeader(headers, "accept")) {
      headers["accept"] = accept
    }

    val body = Struct.getprop(point, "body", null)
    val kind = Struct.getprop(body, "kind", null)
    val media = Struct.getprop(body, "media", null) as? String
    if (("raw" == kind || "json" == kind) && !media.isNullOrEmpty()) {
      headers.entries.removeIf { it.key.lowercase() == "content-type" && isJsonMedia(it.value) }
      if (!hasHeader(headers, "content-type")) {
        headers["content-type"] = media
      }
    }

    return headers
  }

  // Bytes, an InputStream or a String, sent as they are. An InputStream can be
  // read once, so it is read here, before the first attempt, and a retry sends
  // the same bytes again.
  fun rawBody(reqdata: Map<String, Any?>?): Any? {
    val body = reqdata?.get(RAW_BODY)
    return if (body is InputStream) body.readBytes() else body
  }
}
