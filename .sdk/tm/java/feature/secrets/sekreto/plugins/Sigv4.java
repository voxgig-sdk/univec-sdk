// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Sigv4.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps ten ports honest. SigV4 is a stable, published algorithm
// built from HMAC-SHA256, which the JDK already has.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all ten ports must reproduce bit-for-bit,
// and lets the integration mock recompute the signature server-side.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.
//
// IT LIVES WITH THE AWS PLUGIN. Signing is the crypto edge - Mac and
// MessageDigest - and the core of no port imports a hash function.
// Only the two aws kinds sign a request, and both are plugins.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class Sigv4 {

  private Sigv4() {}

  static String hex(byte[] bytes) {
    StringBuilder out = new StringBuilder();
    for (byte b : bytes) {
      out.append(String.format("%02x", b));
    }
    return out.toString();
  }

  static String sha256hex(String text) {
    try {
      return hex(MessageDigest.getInstance("SHA-256")
          .digest(text.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException err) {
      // Every JDK ships SHA-256; a JVM without it cannot sign anything.
      throw new SekretoError("sekreto: sigv4: no SHA-256: " + err.getMessage());
    }
  }

  static byte[] hmac(byte[] key, String text) {
    try {
      Mac mac = Mac.getInstance("HmacSHA256");
      mac.init(new SecretKeySpec(key, "HmacSHA256"));
      return mac.doFinal(text.getBytes(StandardCharsets.UTF_8));
    } catch (java.security.GeneralSecurityException err) {
      throw new SekretoError("sekreto: sigv4: no HmacSHA256: " + err.getMessage());
    }
  }

  /**
   * RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
   * wants everything but unreserved characters escaped, with uppercase hex.
   */
  static String uriescape(String text) {
    StringBuilder out = new StringBuilder();

    for (byte b : text.getBytes(StandardCharsets.UTF_8)) {
      int ch = b & 0xff;
      if (('A' <= ch && 'Z' >= ch)
          || ('a' <= ch && 'z' >= ch)
          || ('0' <= ch && '9' >= ch)
          || '-' == ch || '_' == ch || '.' == ch || '~' == ch) {
        out.append((char) ch);
      } else {
        out.append('%').append(String.format("%02X", ch));
      }
    }

    return out.toString();
  }

  /** Percent-decode, and nothing else: `+` stays `+`, as on the wire. */
  static String uridecode(String text) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();

    for (int index = 0; index < text.length(); index++) {
      char head = text.charAt(index);
      if ('%' == head && index + 2 < text.length()) {
        try {
          out.write(Integer.parseInt(text.substring(index + 1, index + 3), 16));
          index += 2;
          continue;
        } catch (RuntimeException err) {
          // A stray % is kept as-is, the way a browser would.
        }
      }
      byte[] bytes = String.valueOf(head).getBytes(StandardCharsets.UTF_8);
      out.write(bytes, 0, bytes.length);
    }

    return new String(out.toByteArray(), StandardCharsets.UTF_8);
  }

  /**
   * The canonical query string: each pair RFC 3986-escaped, sorted by
   * escaped key then escaped value.
   */
  static String canonicalquery(String query) {
    if (query.isEmpty()) {
      return "";
    }

    List<String[]> pairs = new ArrayList<>();
    for (String pair : query.split("&", -1)) {
      int eq = pair.indexOf('=');
      String key = -1 == eq ? pair : pair.substring(0, eq);
      String value = -1 == eq ? "" : pair.substring(eq + 1);
      pairs.add(new String[] {uriescape(uridecode(key)), uriescape(uridecode(value))});
    }

    Collections.sort(pairs, (left, right) -> {
      int bykey = left[0].compareTo(right[0]);
      return 0 != bykey ? bykey : left[1].compareTo(right[1]);
    });

    List<String> out = new ArrayList<>();
    for (String[] pair : pairs) {
      out.add(pair[0] + "=" + pair[1]);
    }

    return String.join("&", out);
  }

  /**
   * Sign one request. Returns the headers to attach: authorization,
   * x-amz-date, and x-amz-security-token when a session token was given.
   *
   * <p>Input keys: method, url, headers?, body?, service, region, keyid,
   * secret, session?, datetime (YYYYMMDDTHHMMSSZ) - the same declarative
   * shape the shared spec uses.
   */
  @SuppressWarnings("unchecked")
  public static Map<String, Object> sigv4(Map<String, Object> input) {
    URI url = URI.create(String.valueOf(input.get("url")));

    String datetime = String.valueOf(input.get("datetime"));
    String date = datetime.substring(0, 8);

    Object rawbody = input.get("body");
    String body = null == rawbody ? "" : String.valueOf(rawbody);

    String region = String.valueOf(input.get("region"));
    String service = String.valueOf(input.get("service"));

    Object rawsession = input.get("session");
    String session = null == rawsession || String.valueOf(rawsession).isEmpty()
        ? null : String.valueOf(rawsession);

    // Every header that will be signed: the caller's extras, plus host and
    // x-amz-date (and the session token when present), lower-cased and
    // trimmed the way the canonical form requires. A TreeMap keeps them
    // sorted by name, which is the canonical order.
    // Canonical header values are trimmed AND internally collapsed -
    // AWS folds sequential whitespace to one space before signing, so a
    // header like "a  b" must sign as "a b" or the service refuses it.
    TreeMap<String, String> headers = new TreeMap<>();
    Object rawheaders = input.get("headers");
    if (rawheaders instanceof Map) {
      for (Map.Entry<String, Object> entry : ((Map<String, Object>) rawheaders).entrySet()) {
        headers.put(
            // Locale.ROOT: a Turkish JVM lowercases 'I' to a dotless 'i',
            // which changes the signed header names and breaks the signature.
            entry.getKey().toLowerCase(Locale.ROOT),
            String.valueOf(entry.getValue()).trim().replaceAll("\\s+", " "));
      }
    }
    headers.put("host", url.getHost() + (-1 == url.getPort() ? "" : ":" + url.getPort()));
    headers.put("x-amz-date", datetime);
    if (null != session) {
      headers.put("x-amz-security-token", session);
    }

    StringBuilder canonicalheaders = new StringBuilder();
    for (Map.Entry<String, String> entry : headers.entrySet()) {
      canonicalheaders.append(entry.getKey()).append(':').append(entry.getValue()).append('\n');
    }
    String signedheaders = String.join(";", headers.keySet());

    String path = null == url.getRawPath() || url.getRawPath().isEmpty()
        ? "/" : url.getRawPath();
    String query = null == url.getRawQuery() ? "" : url.getRawQuery();

    String canonicalrequest = String.join("\n",
        String.valueOf(input.get("method")).toUpperCase(Locale.ROOT),
        path,
        canonicalquery(query),
        canonicalheaders.toString(),
        signedheaders,
        sha256hex(body));

    String scope = date + "/" + region + "/" + service + "/aws4_request";

    String stringtosign = String.join("\n",
        "AWS4-HMAC-SHA256",
        datetime,
        scope,
        sha256hex(canonicalrequest));

    byte[] kdate = hmac(("AWS4" + input.get("secret")).getBytes(StandardCharsets.UTF_8), date);
    byte[] kregion = hmac(kdate, region);
    byte[] kservice = hmac(kregion, service);
    byte[] ksigning = hmac(kservice, "aws4_request");
    String signature = hex(hmac(ksigning, stringtosign));

    // Insertion order matters: the output is compared as a JSON object by
    // the spec, and printed field by field by callers.
    Map<String, Object> out = new LinkedHashMap<>();
    out.put(
        "authorization",
        "AWS4-HMAC-SHA256 Credential=" + input.get("keyid") + "/" + scope
            + ", SignedHeaders=" + signedheaders
            + ", Signature=" + signature);
    out.put("x-amz-date", datetime);

    if (null != session) {
      out.put("x-amz-security-token", session);
    }

    return out;
  }
}
