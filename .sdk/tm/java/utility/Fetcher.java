package JAVAPACKAGE.utility;

import java.net.InetSocketAddress;
import java.net.ProxySelector;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
final class Fetcher {

  private Fetcher() {}

  static Map<String, Object> defaultHttpFetch(String fullurl, Map<String, Object> fetchdef) {
    String method = fetchdef.get("method") instanceof String
        ? (String) fetchdef.get("method") : "";
    if ("".equals(method)) {
      method = "GET";
    }

    HttpRequest.BodyPublisher bodyPublisher = HttpRequest.BodyPublishers.noBody();
    Object body = fetchdef.get("body");
    if (body instanceof String && !"".equals(body)) {
      bodyPublisher = HttpRequest.BodyPublishers.ofString((String) body);
    }

    HttpRequest.Builder reqb;
    try {
      reqb = HttpRequest.newBuilder(URI.create(fullurl)).method(method, bodyPublisher);
    }
    catch (RuntimeException e) {
      throw new RuntimeException("fetch: invalid url: " + fullurl, e);
    }

    boolean hasUA = false;
    Object headersRaw = fetchdef.get("headers");
    if (headersRaw instanceof Map) {
      for (Map.Entry<String, Object> h : ((Map<String, Object>) headersRaw).entrySet()) {
        if (h.getValue() instanceof String) {
          if ("user-agent".equalsIgnoreCase(h.getKey())) {
            hasUA = true;
          }
          reqb.setHeader(h.getKey(), (String) h.getValue());
        }
      }
    }
    // Default User-Agent — some CDNs block Java's default. Use a
    // Mozilla-shaped UA unless the caller already set one.
    if (!hasUA) {
      reqb.setHeader("User-Agent", "Mozilla/5.0 (compatible; UnivecSDK/1.0)");
    }

    // Honour a redirect annotation on the fetch definition (set by the
    // station feature's middleware under a hosts policy): "manual" returns
    // a 3xx like any other response instead of following it — the ts
    // donor's fetch honours the same key natively, and an automatic follow
    // would carry injected credentials to a host no policy approved.
    HttpClient.Redirect redirectPolicy =
        "manual".equals(fetchdef.get("redirect"))
            ? HttpClient.Redirect.NEVER
            : HttpClient.Redirect.NORMAL;

    // Honour a proxy annotation on the fetch definition (set by the proxy
    // feature): route the request through a proxied HttpClient.
    HttpClient.Builder clientb = HttpClient.newBuilder()
        .followRedirects(redirectPolicy);
    Object proxy = fetchdef.get("proxy");
    if (proxy instanceof String && !"".equals(proxy)) {
      try {
        URI proxyUri = URI.create((String) proxy);
        int port = proxyUri.getPort() < 0 ? 80 : proxyUri.getPort();
        clientb.proxy(ProxySelector.of(new InetSocketAddress(proxyUri.getHost(), port)));
      }
      catch (RuntimeException e) {
        // Unparseable proxy target: fall through to a direct connection,
        // mirroring the go transport (bad proxy URL is ignored).
      }
    }

    HttpResponse<String> resp;
    try {
      resp = clientb.build().send(reqb.build(), HttpResponse.BodyHandlers.ofString());
    }
    catch (Exception e) {
      throw new RuntimeException("fetch: " + e.getMessage(), e);
    }

    Map<String, Object> headers = new LinkedHashMap<>();
    for (Map.Entry<String, List<String>> h : resp.headers().map().entrySet()) {
      List<String> vals = h.getValue();
      if (vals.size() == 1) {
        headers.put(h.getKey().toLowerCase(), vals.get(0));
      }
      else {
        headers.put(h.getKey().toLowerCase(), String.join(", ", vals));
      }
    }

    String bodyText = resp.body() == null ? "" : resp.body();
    final Object jsonBody = bodyText.isEmpty() ? null : Json.parseOrNull(bodyText);

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", resp.statusCode());
    out.put("statusText", statusText(resp.statusCode()));
    out.put("headers", headers);
    out.put("json", (Supplier<Object>) () -> jsonBody);
    out.put("body", bodyText);
    return out;
  }

  // HTTP/2 responses carry no reason phrase; use the standard text for
  // common codes so statusText stays informative.
  static String statusText(int status) {
    switch (status) {
      case 200: return "OK";
      case 201: return "Created";
      case 202: return "Accepted";
      case 204: return "No Content";
      case 301: return "Moved Permanently";
      case 302: return "Found";
      case 304: return "Not Modified";
      case 400: return "Bad Request";
      case 401: return "Unauthorized";
      case 403: return "Forbidden";
      case 404: return "Not Found";
      case 405: return "Method Not Allowed";
      case 408: return "Request Timeout";
      case 409: return "Conflict";
      case 422: return "Unprocessable Entity";
      case 425: return "Too Early";
      case 429: return "Too Many Requests";
      case 500: return "Internal Server Error";
      case 502: return "Bad Gateway";
      case 503: return "Service Unavailable";
      case 504: return "Gateway Timeout";
      default: return "";
    }
  }

  static Object fetcher(Context ctx, String fullurl, Map<String, Object> fetchdef) {
    if (!"live".equals(ctx.client.mode)) {
      throw ctx.makeError("fetch_mode_block",
          "Request blocked by mode: \"" + ctx.client.mode
              + "\" (URL was: \"" + fullurl + "\")");
    }

    Map<String, Object> options = ctx.client.optionsMap();
    if (Boolean.TRUE.equals(Struct.getpath(options,
        List.of("feature", "test", "active")))) {
      throw ctx.makeError("fetch_test_block",
          "Request blocked as test feature is active"
              + " (URL was: \"" + fullurl + "\")");
    }

    Object sysFetch = Struct.getpath(options, List.of("system", "fetch"));
    if (sysFetch == Struct.UNDEF) {
      sysFetch = null;
    }

    if (sysFetch == null) {
      return defaultHttpFetch(fullurl, fetchdef);
    }

    if (sysFetch instanceof BiFunction) {
      return ((BiFunction<String, Map<String, Object>, Object>) sysFetch)
          .apply(fullurl, fetchdef);
    }

    throw ctx.makeError("fetch_invalid", "system.fetch is not a valid function");
  }
}
