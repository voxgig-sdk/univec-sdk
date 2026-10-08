package SCALAPACKAGE.utility

import java.util.{ArrayList, List => JList, Locale, Map => JMap}
import SCALAPACKAGE.utility.struct.Struct

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.
object Media {

  // The data key holding a raw request body. Like `$action`, it can never be
  // a declared argument name.
  val RawBody: String = "$body"

  def isJsonMedia(media: Object): Boolean = {
    val m = (media match { case s: String => s; case _ => "" })
      .split(";", 2)(0).trim.toLowerCase(Locale.ROOT)
    m == "application/json" || m == "text/json" || m.endsWith("+json")
  }

  // The declared JSON type alone, else every declared type in the model's
  // order; null when no success response declares a body.
  def acceptOf(point: Object): String = {
    val res = Struct.getprop(point, "response")
    Struct.getprop(res, "media") match {
      case media: String if media.nonEmpty =>
        if ("json" == Struct.getprop(res, "kind")) media
        else {
          val types = new ArrayList[String]()
          types.add(media)
          Struct.getprop(res, "alternatives") match {
            case alts: JList[_] =>
              alts.forEach { alt =>
                Struct.getprop(alt, "media") match {
                  case m: String if m.nonEmpty => types.add(m)
                  case _ =>
                }
              }
            case _ =>
          }
          String.join(", ", types)
        }
      case _ => null
    }
  }

  def isRawRequest(point: Object): Boolean =
    "raw" == Struct.getprop(Struct.getprop(point, "body"), "kind")

  def isJsonRequest(point: Object): Boolean =
    "json" == Struct.getprop(Struct.getprop(point, "body"), "kind")

  // Bytes or a stream go as given. A map or a list is JSON, and so is a scalar
  // on a point that declares a JSON body.
  def requestBody(point: Object, body: Object): Object = body match {
    case _: Array[Byte] | _: java.io.InputStream => body
    case _ if Struct.isnode(body) || isJsonRequest(point) => Struct.jsonify(body)
    case _ => body
  }

  private def hasHeader(headers: JMap[String, Object], name: String): Boolean =
    headers.keySet().stream().anyMatch(k => k != null && k.toLowerCase(Locale.ROOT) == name)

  // A caller's accept wins. A declared request type replaces each JSON
  // content-type, the SDK default, and leaves any other the caller set.
  def headers(point: Object, headers: JMap[String, Object]): JMap[String, Object] = {
    val accept = acceptOf(point)
    if (accept != null && !hasHeader(headers, "accept")) {
      headers.put("accept", accept)
    }

    val body = Struct.getprop(point, "body")
    val kind = Struct.getprop(body, "kind")
    Struct.getprop(body, "media") match {
      case media: String if media.nonEmpty && ("raw" == kind || "json" == kind) =>
        headers.entrySet().removeIf(e => e.getKey != null &&
          e.getKey.toLowerCase(Locale.ROOT) == "content-type" && isJsonMedia(e.getValue))
        if (!hasHeader(headers, "content-type")) {
          headers.put("content-type", media)
        }
      case _ =>
    }

    headers
  }

  // Bytes, an InputStream or a String, sent as they are. An InputStream can be
  // read once, so it is read here, before the first attempt, and a retry sends
  // the same bytes again.
  def rawBody(reqdata: JMap[String, Object]): Object = {
    val body = if (reqdata == null) null else reqdata.get(RawBody)
    body match {
      case stream: java.io.InputStream => stream.readAllBytes()
      case other => other
    }
  }
}
