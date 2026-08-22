package voxgig.univecsdk.utility

import java.net.InetSocketAddress
import java.net.ProxySelector
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.util.function.BiFunction
import java.util.function.Supplier

import voxgig.univecsdk.core.Context
import voxgig.univecsdk.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
fun defaultHttpFetch(fullurl: String, fetchdef: MutableMap<String, Any?>): MutableMap<String, Any?> {
  var method = if (fetchdef["method"] is String) fetchdef["method"] as String else ""
  if ("" == method) {
    method = "GET"
  }

  var bodyPublisher: HttpRequest.BodyPublisher = HttpRequest.BodyPublishers.noBody()
  val body = fetchdef["body"]
  if (body is String && "" != body) {
    bodyPublisher = HttpRequest.BodyPublishers.ofString(body)
  }

  val reqb: HttpRequest.Builder
  try {
    reqb = HttpRequest.newBuilder(URI.create(fullurl)).method(method, bodyPublisher)
  } catch (e: RuntimeException) {
    throw RuntimeException("fetch: invalid url: $fullurl", e)
  }

  var hasUA = false
  val headersRaw = fetchdef["headers"]
  if (headersRaw is MutableMap<*, *>) {
    for (h in (headersRaw as MutableMap<String, Any?>).entries) {
      val hv = h.value
      if (hv is String) {
        if ("user-agent".equals(h.key, ignoreCase = true)) {
          hasUA = true
        }
        reqb.setHeader(h.key, hv)
      }
    }
  }
  // Default User-Agent — some CDNs block Java's default.
  if (!hasUA) {
    reqb.setHeader("User-Agent", "Mozilla/5.0 (compatible; UnivecSDK/1.0)")
  }

  // Honour a redirect annotation on the fetch definition (set by the
  // station feature's middleware under a hosts policy): "manual" returns
  // a 3xx like any other response instead of following it — the ts
  // donor's fetch honours the same key natively, and an automatic follow
  // would carry injected credentials to a host no policy approved.
  val redirectPolicy =
    if ("manual" == fetchdef["redirect"]) HttpClient.Redirect.NEVER
    else HttpClient.Redirect.NORMAL

  // Honour a proxy annotation on the fetch definition (set by the proxy
  // feature): route the request through a proxied HttpClient.
  val clientb = HttpClient.newBuilder().followRedirects(redirectPolicy)
  val proxy = fetchdef["proxy"]
  if (proxy is String && "" != proxy) {
    try {
      val proxyUri = URI.create(proxy)
      val port = if (proxyUri.port < 0) 80 else proxyUri.port
      clientb.proxy(ProxySelector.of(InetSocketAddress(proxyUri.host, port)))
    } catch (e: RuntimeException) {
      // Unparseable proxy target: fall through to a direct connection.
    }
  }

  val resp: HttpResponse<String>
  try {
    resp = clientb.build().send(reqb.build(), HttpResponse.BodyHandlers.ofString())
  } catch (e: Exception) {
    throw RuntimeException("fetch: " + e.message, e)
  }

  val headers = linkedMapOf<String, Any?>()
  for ((k, vals) in resp.headers().map()) {
    if (vals.size == 1) {
      headers[k.lowercase()] = vals[0]
    } else {
      headers[k.lowercase()] = vals.joinToString(", ")
    }
  }

  val bodyText = resp.body() ?: ""
  val jsonBody: Any? = if (bodyText.isEmpty()) null else Json.parseOrNull(bodyText)

  val out = linkedMapOf<String, Any?>()
  out["status"] = resp.statusCode()
  out["statusText"] = statusText(resp.statusCode())
  out["headers"] = headers
  out["json"] = Supplier<Any?> { jsonBody }
  out["body"] = bodyText
  return out
}

// HTTP/2 responses carry no reason phrase; use the standard text for
// common codes so statusText stays informative.
fun statusText(status: Int): String {
  return when (status) {
    200 -> "OK"
    201 -> "Created"
    202 -> "Accepted"
    204 -> "No Content"
    301 -> "Moved Permanently"
    302 -> "Found"
    304 -> "Not Modified"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    408 -> "Request Timeout"
    409 -> "Conflict"
    422 -> "Unprocessable Entity"
    425 -> "Too Early"
    429 -> "Too Many Requests"
    500 -> "Internal Server Error"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    504 -> "Gateway Timeout"
    else -> ""
  }
}

@Suppress("UNCHECKED_CAST")
fun fetcher(ctx: Context, fullurl: String, fetchdef: MutableMap<String, Any?>): Any? {
  if ("live" != ctx.client!!.mode) {
    throw ctx.makeError(
      "fetch_mode_block",
      "Request blocked by mode: \"" + ctx.client!!.mode +
        "\" (URL was: \"" + fullurl + "\")",
    )
  }

  val options = ctx.client!!.optionsMap()
  if (Struct.getpath(options, listOf("feature", "test", "active")) == true) {
    throw ctx.makeError(
      "fetch_test_block",
      "Request blocked as test feature is active (URL was: \"" + fullurl + "\")",
    )
  }

  var sysFetch = Struct.getpath(options, listOf("system", "fetch"))
  if (sysFetch === Struct.UNDEF) {
    sysFetch = null
  }

  if (sysFetch == null) {
    return defaultHttpFetch(fullurl, fetchdef)
  }

  if (sysFetch is BiFunction<*, *, *>) {
    return (sysFetch as BiFunction<String, MutableMap<String, Any?>, Any?>).apply(fullurl, fetchdef)
  }

  throw ctx.makeError("fetch_invalid", "system.fetch is not a valid function")
}
