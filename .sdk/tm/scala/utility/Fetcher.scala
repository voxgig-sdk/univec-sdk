package SCALAPACKAGE.utility

import java.net.{InetSocketAddress, ProxySelector, URI}
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.util.{LinkedHashMap, List => JList, Map => JMap}
import java.util.function.{BiFunction, Supplier}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object Fetcher {

  def defaultHttpFetch(fullurl: String, fetchdef: JMap[String, Object]): JMap[String, Object] = {
    var method = fetchdef.get("method") match { case s: String => s; case _ => "" }
    if ("" == method) method = "GET"

    var bodyPublisher = HttpRequest.BodyPublishers.noBody()
    fetchdef.get("body") match {
      case b: String if b != "" => bodyPublisher = HttpRequest.BodyPublishers.ofString(b)
      case _ =>
    }

    val reqb =
      try HttpRequest.newBuilder(URI.create(fullurl)).method(method, bodyPublisher)
      catch { case e: RuntimeException => throw new RuntimeException("fetch: invalid url: " + fullurl, e) }

    var hasUA = false
    fetchdef.get("headers") match {
      case hm: JMap[_, _] =>
        val it = hm.asInstanceOf[JMap[String, Object]].entrySet().iterator()
        while (it.hasNext) {
          val e = it.next()
          e.getValue match {
            case v: String =>
              if ("user-agent".equalsIgnoreCase(e.getKey)) hasUA = true
              reqb.setHeader(e.getKey, v)
            case _ =>
          }
        }
      case _ =>
    }
    if (!hasUA) reqb.setHeader("User-Agent", "Mozilla/5.0 (compatible; UnivecSDK/1.0)")

    val clientb = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL)
    fetchdef.get("proxy") match {
      case proxy: String if proxy != "" =>
        try {
          val proxyUri = URI.create(proxy)
          val port = if (proxyUri.getPort < 0) 80 else proxyUri.getPort
          clientb.proxy(ProxySelector.of(new InetSocketAddress(proxyUri.getHost, port)))
        } catch { case _: RuntimeException => }
      case _ =>
    }

    val resp =
      try clientb.build().send(reqb.build(), HttpResponse.BodyHandlers.ofString())
      catch { case e: Exception => throw new RuntimeException("fetch: " + e.getMessage, e) }

    val headers = new LinkedHashMap[String, Object]()
    val hit = resp.headers().map().entrySet().iterator()
    while (hit.hasNext) {
      val h = hit.next()
      val vals = h.getValue
      if (vals.size() == 1) headers.put(h.getKey.toLowerCase, vals.get(0))
      else headers.put(h.getKey.toLowerCase, String.join(", ", vals))
    }

    val bodyText = if (resp.body() == null) "" else resp.body()
    val jsonBody: Object = if (bodyText.isEmpty) null else Json.parseOrNull(bodyText)
    val jsonSupplier: Supplier[Object] = () => jsonBody

    val out = new LinkedHashMap[String, Object]()
    out.put("status", java.lang.Integer.valueOf(resp.statusCode()))
    out.put("statusText", statusText(resp.statusCode()))
    out.put("headers", headers)
    out.put("json", jsonSupplier)
    out.put("body", bodyText)
    out
  }

  def statusText(status: Int): String = status match {
    case 200 => "OK"
    case 201 => "Created"
    case 202 => "Accepted"
    case 204 => "No Content"
    case 301 => "Moved Permanently"
    case 302 => "Found"
    case 304 => "Not Modified"
    case 400 => "Bad Request"
    case 401 => "Unauthorized"
    case 403 => "Forbidden"
    case 404 => "Not Found"
    case 405 => "Method Not Allowed"
    case 408 => "Request Timeout"
    case 409 => "Conflict"
    case 422 => "Unprocessable Entity"
    case 425 => "Too Early"
    case 429 => "Too Many Requests"
    case 500 => "Internal Server Error"
    case 502 => "Bad Gateway"
    case 503 => "Service Unavailable"
    case 504 => "Gateway Timeout"
    case _ => ""
  }

  def fetcher(ctx: Context, fullurl: String, fetchdef: JMap[String, Object]): Object = {
    if ("live" != ctx.client.mode) {
      throw ctx.makeError("fetch_mode_block",
        "Request blocked by mode: \"" + ctx.client.mode + "\" (URL was: \"" + fullurl + "\")")
    }

    val options = ctx.client.optionsMap()
    if (java.lang.Boolean.TRUE == Struct.getpath(options, java.util.List.of("feature", "test", "active"))) {
      throw ctx.makeError("fetch_test_block",
        "Request blocked as test feature is active (URL was: \"" + fullurl + "\")")
    }

    var sysFetch = Struct.getpath(options, java.util.List.of("system", "fetch"))
    if (sysFetch eq Struct.UNDEF) sysFetch = null

    if (sysFetch == null) return defaultHttpFetch(fullurl, fetchdef)

    sysFetch match {
      case bf: BiFunction[_, _, _] =>
        bf.asInstanceOf[BiFunction[String, JMap[String, Object], Object]].apply(fullurl, fetchdef)
      case _ =>
        throw ctx.makeError("fetch_invalid", "system.fetch is not a valid function")
    }
  }
}
