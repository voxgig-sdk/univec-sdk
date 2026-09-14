// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/src/com/voxgig/sekreto/Json.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Minimal JSON support for sekreto.
//
// sekreto adds no third-party dependencies, so it carries just enough JSON
// to read a vault's answer and write the CLI's own line of output. It is
// deliberately not a general-purpose library.
//
// Parses into plain Java values:
//   object  -> LinkedHashMap<String,Object> (insertion ordered)
//   array   -> ArrayList<Object>
//   string  -> String
//   number  -> Double
//   boolean -> Boolean
//   null    -> null

package JAVAPACKAGE.feature.secrets.sekreto;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Json {

  private Json() {}

  private static final class Reader {
    private final String text;
    private int at;

    Reader(String text) {
      this.text = text;
    }

    void skip() {
      while (at < text.length() && Character.isWhitespace(text.charAt(at))) {
        at++;
      }
    }

    char peek() {
      return at < text.length() ? text.charAt(at) : '\0';
    }

    boolean done() {
      return at >= text.length();
    }

    Object value() {
      skip();

      if (done()) {
        return null;
      }

      char head = peek();

      if ('{' == head) {
        return object();
      }
      if ('[' == head) {
        return array();
      }
      if ('"' == head) {
        return string();
      }
      if (text.startsWith("true", at)) {
        at += 4;
        return Boolean.TRUE;
      }
      if (text.startsWith("false", at)) {
        at += 5;
        return Boolean.FALSE;
      }
      if (text.startsWith("null", at)) {
        at += 4;
        return null;
      }

      return number();
    }

    Map<String, Object> object() {
      Map<String, Object> out = new LinkedHashMap<>();
      at++; // {
      skip();

      if ('}' == peek()) {
        at++;
        return out;
      }

      while (!done()) {
        skip();
        String key = string();
        skip();
        at++; // :
        out.put(key, value());
        skip();

        if (',' == peek()) {
          at++;
          continue;
        }

        at++; // }
        break;
      }

      return out;
    }

    List<Object> array() {
      List<Object> out = new ArrayList<>();
      at++; // [
      skip();

      if (']' == peek()) {
        at++;
        return out;
      }

      while (!done()) {
        out.add(value());
        skip();

        if (',' == peek()) {
          at++;
          continue;
        }

        at++; // ]
        break;
      }

      return out;
    }

    String string() {
      StringBuilder out = new StringBuilder();
      at++; // opening quote

      while (at < text.length()) {
        char head = text.charAt(at++);

        if ('"' == head) {
          break;
        }

        if ('\\' != head) {
          out.append(head);
          continue;
        }

        char next = text.charAt(at++);
        switch (next) {
          case 'n':
            out.append('\n');
            break;
          case 'r':
            out.append('\r');
            break;
          case 't':
            out.append('\t');
            break;
          case 'b':
            out.append('\b');
            break;
          case 'f':
            out.append('\f');
            break;
          case 'u':
            out.append((char) Integer.parseInt(text.substring(at, at + 4), 16));
            at += 4;
            break;
          default:
            out.append(next);
        }
      }

      return out.toString();
    }

    Double number() {
      int start = at;

      while (at < text.length() && 0 > "]},\n\r\t ".indexOf(text.charAt(at))) {
        at++;
      }

      try {
        return Double.valueOf(text.substring(start, at));
      } catch (NumberFormatException err) {
        return null;
      }
    }
  }

  /** Parse JSON text, answering null for anything unreadable. */
  public static Object parse(String text) {
    if (null == text || text.isEmpty()) {
      return null;
    }

    try {
      return new Reader(text).value();
    } catch (RuntimeException err) {
      return null;
    }
  }

  /** Render a value as compact JSON. */
  public static String stringify(Object value) {
    StringBuilder out = new StringBuilder();
    write(value, out);
    return out.toString();
  }

  private static void write(Object value, StringBuilder out) {
    if (null == value) {
      out.append("null");
      return;
    }

    if (value instanceof String) {
      quote((String) value, out);
      return;
    }

    if (value instanceof Boolean || value instanceof Number) {
      out.append(String.valueOf(value));
      return;
    }

    if (value instanceof Map) {
      out.append('{');
      boolean first = true;
      for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
        if (!first) {
          out.append(',');
        }
        first = false;
        quote(String.valueOf(entry.getKey()), out);
        out.append(':');
        write(entry.getValue(), out);
      }
      out.append('}');
      return;
    }

    if (value instanceof List) {
      out.append('[');
      boolean first = true;
      for (Object item : (List<?>) value) {
        if (!first) {
          out.append(',');
        }
        first = false;
        write(item, out);
      }
      out.append(']');
      return;
    }

    quote(String.valueOf(value), out);
  }

  private static void quote(String text, StringBuilder out) {
    out.append('"');

    for (int index = 0; index < text.length(); index++) {
      char head = text.charAt(index);
      switch (head) {
        case '"':
          out.append("\\\"");
          break;
        case '\\':
          out.append("\\\\");
          break;
        case '\n':
          out.append("\\n");
          break;
        case '\r':
          out.append("\\r");
          break;
        case '\t':
          out.append("\\t");
          break;
        default:
          if (0x20 > head) {
            out.append(String.format("\\u%04x", (int) head));
          } else {
            out.append(head);
          }
      }
    }

    out.append('"');
  }
}
