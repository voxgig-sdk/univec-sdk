// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Httpjson.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// One JSON round-trip, shared by every plugin that speaks HTTP - and by
// nothing in the core. A chain of built-ins never links this file, which
// is the whole point of the split: an app configured from a `.env` and
// the environment carries no HTTP client at all.
//
// A port of typescript/plugins/httpjson.ts.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import JAVAPACKAGE.feature.secrets.sekreto.Json;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

public final class Httpjson {

  private Httpjson() {}

  /**
   * How much of a response body will be read before the store is treated as
   * having answered incoherently. Ports carry the same bound.
   *
   * <p>Far above anything real - the largest legitimate payload this library
   * fetches is Doppler's whole-config download, measured in kilobytes. A
   * bound is needed because the TIMEOUT is not one: ten seconds on a loopback
   * or datacentre link is gigabytes, and the body is accumulated in memory
   * before it is parsed. This runs on an application's startup path, so the
   * failure is the application never starting.
   */
  private static final int MAXBODY = 8 * 1024 * 1024;

  // HTTP/1.1, explicitly.
  //
  // java.net.http defaults to HTTP_2, and over cleartext that means an h2c
  // upgrade: the first request goes out with `Upgrade: h2c`, the declared
  // Content-Length, and NO BODY, and the body follows only after the server
  // declines. A server that checks the two against each other - Fastify
  // does, and Infisical is Fastify - rejects that request outright with
  // "Request body size did not match Content-Length", so every POST this
  // port makes to such a server fails before it is even read.
  //
  // The mocks in test/ are Node's own http module, which does not object,
  // which is why this survived until the same code met a real Infisical.
  // No vault API this library speaks needs HTTP/2.
  private static final HttpClient CLIENT = HttpClient.newBuilder()
      .version(HttpClient.Version.HTTP_1_1)
      .connectTimeout(Duration.ofSeconds(10))
      .build();

  /** One JSON round-trip's result: the status, and the parsed body. */
  public static final class Answer {
    final int status;
    final Object body;

    Answer(int status, Object body) {
      this.status = status;
      this.body = body;
    }
  }

  /**
   * One JSON round-trip. Network failure is always an error - an
   * unreachable store is a store that could not answer.
   */
  public static Answer fetchjson(String method, String url, Map<String, String> headers, String body) {
    HttpRequest.Builder builder = HttpRequest.newBuilder()
        .uri(URI.create(url))
        .timeout(Duration.ofSeconds(10))
        .method(method, null == body
            ? HttpRequest.BodyPublishers.noBody()
            : HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));

    if (null != headers) {
      for (Map.Entry<String, String> entry : headers.entrySet()) {
        builder.header(entry.getKey(), entry.getValue());
      }
    }

    // ofInputStream, not ofString: ofString buffers whatever arrives, so an
    // endless body would be accumulated in memory until the deadline - which
    // on a loopback or datacentre link is gigabytes.
    HttpResponse<java.io.InputStream> response;
    try {
      response = CLIENT.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream());
    } catch (IOException err) {
      throw new SekretoError(
          "sekreto: cannot reach " + url.split("\\?")[0] + ": " + err.getMessage());
    } catch (InterruptedException err) {
      Thread.currentThread().interrupt();
      throw new SekretoError("sekreto: cannot reach " + url.split("\\?")[0] + ": interrupted");
    }

    String text;
    try (java.io.InputStream stream = response.body()) {
      // One byte over the bound is enough to know it was exceeded. An
      // endless body is a store that could not answer, so this raises
      // rather than returning a miss - the latter would fall through to a
      // weaker store on an attacker's cue.
      byte[] raw = stream.readNBytes(MAXBODY + 1);
      if (MAXBODY < raw.length) {
        throw new SekretoError("sekreto: oversized response from " + url.split("\\?")[0]);
      }
      text = new String(raw, StandardCharsets.UTF_8);
    } catch (IOException err) {
      throw new SekretoError(
          "sekreto: cannot reach " + url.split("\\?")[0] + ": " + err.getMessage());
    }

    // A success status promised JSON; a body that does not parse means
    // the store could not answer coherently, and treating it as a miss
    // would fall through to a weaker store. Error statuses may carry
    // any body - they are decided on status alone. (Json.parse answers
    // null for anything unreadable, and only a literal `null` body is a
    // genuine JSON null.)
    Object parsed = Json.parse(text);
    if (200 == response.statusCode() && null == parsed && !"null".equals(text.trim())) {
      throw new SekretoError("sekreto: malformed response from " + url.split("\\?")[0]);
    }

    return new Answer(response.statusCode(), parsed);
  }

  /** A one-pair header map, the shape most requests here need. */
  public static Map<String, String> headers(String... pairs) {
    Map<String, String> out = new LinkedHashMap<>();
    for (int index = 0; index + 1 < pairs.length; index += 2) {
      out.put(pairs[index], pairs[index + 1]);
    }
    return out;
  }

  /** Walk nested JSON maps; null the moment a step is not there. */
  @SuppressWarnings("unchecked")
  public static Object dig(Object value, String... keys) {
    for (String key : keys) {
      if (!(value instanceof Map)) {
        return null;
      }
      value = ((Map<String, Object>) value).get(key);
    }
    return value;
  }

  /** The first value that is set and non-empty, or empty. */
  public static String first(String... candidates) {
    for (String candidate : candidates) {
      if (null != candidate && !candidate.isEmpty()) {
        return candidate;
      }
    }
    return "";
  }

  /**
   * When a logged-in token must be renewed, from its expiry in seconds
   * (a JSON number, or a string as Azure IMDS sends it): now +
   * max(seconds - 60, 1). A missing or zero expiry means never renew.
   */
  public static long renewtime(Object expires) {
    double seconds = 0;
    if (expires instanceof Number) {
      seconds = ((Number) expires).doubleValue();
    } else if (expires instanceof String) {
      try {
        seconds = Double.parseDouble((String) expires);
      } catch (NumberFormatException err) {
        seconds = 0;
      }
    }

    if (0 >= seconds || Double.isNaN(seconds)) {
      return Long.MAX_VALUE;
    }

    return System.currentTimeMillis() + (long) (Math.max(seconds - 60, 1) * 1000);
  }

  /** An address with any trailing slash removed. */
  public static String trimslash(String text) {
    return text.endsWith("/") ? text.substring(0, text.length() - 1) : text;
  }
}
