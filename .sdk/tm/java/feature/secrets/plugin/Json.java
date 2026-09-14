// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Json.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * The JSON value model, and the only parser this port has.
 *
 * <p>NO JACKSON, NO GSON, NO JUNIT (§16). The library is allowed exactly
 * one runtime dependency, {@code voxgig/struct}, which has no java port;
 * everything else is the JDK. Parsing the corpus is two hundred lines, and
 * two hundred lines is cheaper than a dependency every embedding host
 * inherits.
 *
 * <p>THE VALUE MODEL IS PLAIN {@code Object}, and each JSON type has ONE
 * java spelling: {@code null}, {@link Boolean}, {@link Double}, {@link
 * String}, {@code List<Object>}, {@code Map<String,Object>}. A map is
 * always a {@link TreeMap} - every port has to sort its keys before
 * iterating, and a sorted map makes that the default rather than a
 * discipline to remember.
 *
 * <p>A NUMBER IS ALWAYS A {@code Double}, because JSON has one number type
 * and the canonical is javascript. An {@code Integer} anywhere in this
 * data would compare unequal to the {@code Double} the parser produced for
 * the same literal - {@code Integer.valueOf(1).equals(Double.valueOf(1))}
 * is false - and the corpus would fail on a distinction the model does not
 * have.
 */
public final class Json {

  private Json() {}

  public static Object parse(String text) {
    Parser parser = new Parser(text);
    parser.skipws();
    Object value = parser.value();
    parser.skipws();
    if (parser.at < parser.chars.length) {
      throw new IllegalArgumentException("trailing input at " + parser.at);
    }
    return value;
  }

  /** Compact JSON, map keys in sorted order (which a TreeMap already is). */
  public static String write(Object value) {
    StringBuilder out = new StringBuilder();
    writeTo(value, out);
    return out.toString();
  }

  @SuppressWarnings("unchecked")
  private static void writeTo(Object value, StringBuilder out) {
    if (null == value) {
      out.append("null");
      return;
    }
    if (value instanceof Boolean) {
      out.append(((Boolean) value) ? "true" : "false");
      return;
    }
    if (value instanceof Double) {
      double n = (Double) value;
      // An integral double prints without a fractional part, so a `pos` of
      // 3 renders as `3` and not `3.0` - JSON has one number type and the
      // corpus writes them as it means them.
      if (n == Math.floor(n) && !Double.isInfinite(n) && Math.abs(n) < 1e15) {
        out.append((long) n);
      } else {
        out.append(n);
      }
      return;
    }
    if (value instanceof String) {
      writeString((String) value, out);
      return;
    }
    if (value instanceof List) {
      out.append('[');
      boolean first = true;
      for (Object item : (List<Object>) value) {
        if (!first) {
          out.append(',');
        }
        first = false;
        writeTo(item, out);
      }
      out.append(']');
      return;
    }
    if (value instanceof Map) {
      out.append('{');
      boolean first = true;
      for (Map.Entry<String, Object> e : ((Map<String, Object>) value).entrySet()) {
        if (!first) {
          out.append(',');
        }
        first = false;
        writeString(e.getKey(), out);
        out.append(':');
        writeTo(e.getValue(), out);
      }
      out.append('}');
      return;
    }
    // A host object published through `exports` (§11) - the library never
    // inspects one and nothing in the corpus compares one.
    out.append("\"(opaque)\"");
  }

  private static void writeString(String text, StringBuilder out) {
    out.append('"');
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      switch (c) {
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
          if (c < 0x20) {
            out.append(String.format("\\u%04x", (int) c));
          } else {
            out.append(c);
          }
      }
    }
    out.append('"');
  }

  private static final class Parser {
    private final char[] chars;
    private int at;

    Parser(String text) {
      this.chars = text.toCharArray();
      this.at = 0;
    }

    void skipws() {
      while (at < chars.length
          && (' ' == chars[at] || '\t' == chars[at] || '\n' == chars[at] || '\r' == chars[at])) {
        at++;
      }
    }

    Object value() {
      if (chars.length <= at) {
        throw new IllegalArgumentException("unexpected end of input");
      }
      switch (chars[at]) {
        case '{':
          return map();
        case '[':
          return list();
        case '"':
          return string();
        case 't':
          return literal("true", Boolean.TRUE);
        case 'f':
          return literal("false", Boolean.FALSE);
        case 'n':
          return literal("null", null);
        default:
          return number();
      }
    }

    Object literal(String word, Object value) {
      for (int i = 0; i < word.length(); i++) {
        if (chars.length <= at + i || chars[at + i] != word.charAt(i)) {
          throw new IllegalArgumentException("bad literal at " + at);
        }
      }
      at += word.length();
      return value;
    }

    Object map() {
      Map<String, Object> out = new TreeMap<>();
      at++;
      skipws();
      if (at < chars.length && '}' == chars[at]) {
        at++;
        return out;
      }
      while (true) {
        skipws();
        String key = string();
        skipws();
        if (chars.length <= at || ':' != chars[at]) {
          throw new IllegalArgumentException("expected ':' at " + at);
        }
        at++;
        skipws();
        out.put(key, value());
        skipws();
        if (chars.length <= at) {
          throw new IllegalArgumentException("unexpected end in object");
        }
        if (',' == chars[at]) {
          at++;
          continue;
        }
        if ('}' == chars[at]) {
          at++;
          return out;
        }
        throw new IllegalArgumentException("expected ',' or '}' at " + at);
      }
    }

    Object list() {
      List<Object> out = new ArrayList<>();
      at++;
      skipws();
      if (at < chars.length && ']' == chars[at]) {
        at++;
        return out;
      }
      while (true) {
        skipws();
        out.add(value());
        skipws();
        if (chars.length <= at) {
          throw new IllegalArgumentException("unexpected end in array");
        }
        if (',' == chars[at]) {
          at++;
          continue;
        }
        if (']' == chars[at]) {
          at++;
          return out;
        }
        throw new IllegalArgumentException("expected ',' or ']' at " + at);
      }
    }

    String string() {
      if (chars.length <= at || '"' != chars[at]) {
        throw new IllegalArgumentException("expected a string at " + at);
      }
      at++;
      StringBuilder out = new StringBuilder();
      while (at < chars.length) {
        char c = chars[at];
        at++;
        if ('"' == c) {
          return out.toString();
        }
        if ('\\' != c) {
          out.append(c);
          continue;
        }
        if (chars.length <= at) {
          throw new IllegalArgumentException("unexpected end in string");
        }
        char e = chars[at];
        at++;
        switch (e) {
          case '"':
            out.append('"');
            break;
          case '\\':
            out.append('\\');
            break;
          case '/':
            out.append('/');
            break;
          case 'b':
            out.append('\b');
            break;
          case 'f':
            out.append('\f');
            break;
          case 'n':
            out.append('\n');
            break;
          case 'r':
            out.append('\r');
            break;
          case 't':
            out.append('\t');
            break;
          case 'u':
            // A java char IS a UTF-16 code unit, so a surrogate pair needs
            // no joining here: appending both halves is the string.
            if (chars.length < at + 4) {
              throw new IllegalArgumentException("bad \\u escape at " + at);
            }
            out.append((char) Integer.parseInt(new String(chars, at, 4), 16));
            at += 4;
            break;
          default:
            throw new IllegalArgumentException("bad escape at " + at);
        }
      }
      throw new IllegalArgumentException("unterminated string");
    }

    Object number() {
      int start = at;
      if (at < chars.length && '-' == chars[at]) {
        at++;
      }
      while (at < chars.length
          && (Character.isDigit(chars[at])
              || '.' == chars[at]
              || 'e' == chars[at]
              || 'E' == chars[at]
              || '+' == chars[at]
              || '-' == chars[at])) {
        at++;
      }
      String text = new String(chars, start, at - start);
      try {
        return Double.valueOf(text);
      } catch (NumberFormatException e) {
        throw new IllegalArgumentException("bad number " + text + " at " + start);
      }
    }
  }
}
