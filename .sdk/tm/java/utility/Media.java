package JAVAPACKAGE.utility;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import JAVAPACKAGE.utility.struct.Struct;

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.
final class Media {

  // The data key holding a raw request body. Like `$action`, it can never be
  // a declared argument name.
  static final String RAW_BODY = "$body";

  private Media() {}

  static boolean isJsonMedia(Object media) {
    String m = (media instanceof String ? (String) media : "").split(";", 2)[0]
        .trim().toLowerCase(Locale.ROOT);
    return "application/json".equals(m) || "text/json".equals(m) || m.endsWith("+json");
  }

  // The declared JSON type alone, else every declared type in the model's
  // order; null when no success response declares a body.
  static String acceptOf(Object point) {
    Object res = Struct.getprop(point, "response");
    Object media = Struct.getprop(res, "media");
    if (!(media instanceof String) || ((String) media).isEmpty()) {
      return null;
    }
    if ("json".equals(Struct.getprop(res, "kind"))) {
      return (String) media;
    }
    List<String> types = new ArrayList<>();
    types.add((String) media);
    Object alts = Struct.getprop(res, "alternatives");
    if (alts instanceof List) {
      for (Object alt : (List<?>) alts) {
        Object m = Struct.getprop(alt, "media");
        if (m instanceof String && !((String) m).isEmpty()) {
          types.add((String) m);
        }
      }
    }
    return String.join(", ", types);
  }

  static boolean isRawRequest(Object point) {
    return "raw".equals(Struct.getprop(Struct.getprop(point, "body"), "kind"));
  }

  static boolean isJsonRequest(Object point) {
    return "json".equals(Struct.getprop(Struct.getprop(point, "body"), "kind"));
  }

  // Bytes or a stream go as given. A map or a list is JSON, and so is a scalar
  // on a point that declares a JSON body.
  static Object requestBody(Object point, Object body) {
    if (body instanceof byte[] || body instanceof InputStream) {
      return body;
    }
    if (Struct.isnode(body) || isJsonRequest(point)) {
      return Struct.jsonify(body);
    }
    return body;
  }

  private static boolean hasHeader(Map<String, Object> headers, String name) {
    return headers.keySet().stream()
        .anyMatch(k -> k != null && k.toLowerCase(Locale.ROOT).equals(name));
  }

  // A caller's accept wins. A declared request type replaces each JSON
  // content-type, the SDK default, and leaves any other the caller set.
  static Map<String, Object> headers(Object point, Map<String, Object> headers) {
    String accept = acceptOf(point);
    if (accept != null && !hasHeader(headers, "accept")) {
      headers.put("accept", accept);
    }

    Object body = Struct.getprop(point, "body");
    Object kind = Struct.getprop(body, "kind");
    Object media = Struct.getprop(body, "media");
    if (("raw".equals(kind) || "json".equals(kind)) &&
        media instanceof String && !((String) media).isEmpty()) {
      headers.entrySet().removeIf(e -> e.getKey() != null &&
          "content-type".equals(e.getKey().toLowerCase(Locale.ROOT)) && isJsonMedia(e.getValue()));
      if (!hasHeader(headers, "content-type")) {
        headers.put("content-type", media);
      }
    }

    return headers;
  }

  // Bytes, an InputStream or a String, sent as they are. An InputStream can be
  // read once, so it is read here, before the first attempt, and a retry sends
  // the same bytes again.
  static Object rawBody(Map<String, Object> reqdata) {
    Object body = reqdata == null ? null : reqdata.get(RAW_BODY);
    if (body instanceof InputStream) {
      try {
        return ((InputStream) body).readAllBytes();
      }
      catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }
    return body;
  }
}
