package SCALAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal zero-dependency JSON parser for the Univec SDK runtime.
 * Produces the same shapes the rest of the runtime consumes:
 * LinkedHashMap&lt;String,Object&gt;, ArrayList&lt;Object&gt;, String,
 * Long (integer-valued numbers), Double, Boolean and null.
 *
 * Serialization is handled by the vendored Struct.jsonify; this class only
 * parses. {@link #parse} throws IllegalArgumentException on malformed input;
 * {@link #parseOrNull} returns null instead (used by the HTTP fetcher for
 * non-JSON bodies).
 */
public final class Json {

  private Json() {}

  public static Object parse(String src) {
    if (src == null) {
      throw new IllegalArgumentException("json: null input");
    }
    Parser p = new Parser(src);
    p.ws();
    Object out = p.value();
    p.ws();
    if (!p.done()) {
      throw new IllegalArgumentException("json: trailing content at " + p.pos);
    }
    return out;
  }

  public static Object parseOrNull(String src) {
    try {
      return parse(src);
    }
    catch (RuntimeException e) {
      return null;
    }
  }

  private static final class Parser {
    final String s;
    int pos = 0;

    Parser(String s) {
      this.s = s;
    }

    boolean done() {
      return pos >= s.length();
    }

    void ws() {
      while (pos < s.length()) {
        char c = s.charAt(pos);
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
          pos++;
        }
        else {
          break;
        }
      }
    }

    char peek() {
      if (pos >= s.length()) {
        throw new IllegalArgumentException("json: unexpected end of input");
      }
      return s.charAt(pos);
    }

    void expect(char c) {
      if (peek() != c) {
        throw new IllegalArgumentException(
            "json: expected '" + c + "' at " + pos + ", got '" + peek() + "'");
      }
      pos++;
    }

    Object value() {
      char c = peek();
      switch (c) {
        case '{':
          return object();
        case '[':
          return array();
        case '"':
          return string();
        case 't':
          literal("true");
          return Boolean.TRUE;
        case 'f':
          literal("false");
          return Boolean.FALSE;
        case 'n':
          literal("null");
          return null;
        default:
          if (c == '-' || (c >= '0' && c <= '9')) {
            return number();
          }
          throw new IllegalArgumentException("json: unexpected '" + c + "' at " + pos);
      }
    }

    void literal(String lit) {
      if (!s.startsWith(lit, pos)) {
        throw new IllegalArgumentException("json: invalid literal at " + pos);
      }
      pos += lit.length();
    }

    Map<String, Object> object() {
      expect('{');
      Map<String, Object> out = new LinkedHashMap<>();
      ws();
      if (peek() == '}') {
        pos++;
        return out;
      }
      while (true) {
        ws();
        String key = string();
        ws();
        expect(':');
        ws();
        out.put(key, value());
        ws();
        char c = peek();
        if (c == ',') {
          pos++;
          continue;
        }
        if (c == '}') {
          pos++;
          return out;
        }
        throw new IllegalArgumentException("json: expected ',' or '}' at " + pos);
      }
    }

    List<Object> array() {
      expect('[');
      List<Object> out = new ArrayList<>();
      ws();
      if (peek() == ']') {
        pos++;
        return out;
      }
      while (true) {
        ws();
        out.add(value());
        ws();
        char c = peek();
        if (c == ',') {
          pos++;
          continue;
        }
        if (c == ']') {
          pos++;
          return out;
        }
        throw new IllegalArgumentException("json: expected ',' or ']' at " + pos);
      }
    }

    String string() {
      expect('"');
      StringBuilder b = new StringBuilder();
      while (true) {
        if (pos >= s.length()) {
          throw new IllegalArgumentException("json: unterminated string");
        }
        char c = s.charAt(pos++);
        if (c == '"') {
          return b.toString();
        }
        if (c == '\\') {
          if (pos >= s.length()) {
            throw new IllegalArgumentException("json: unterminated escape");
          }
          char e = s.charAt(pos++);
          switch (e) {
            case '"':
              b.append('"');
              break;
            case '\\':
              b.append('\\');
              break;
            case '/':
              b.append('/');
              break;
            case 'b':
              b.append('\b');
              break;
            case 'f':
              b.append('\f');
              break;
            case 'n':
              b.append('\n');
              break;
            case 'r':
              b.append('\r');
              break;
            case 't':
              b.append('\t');
              break;
            case 'u':
              if (pos + 4 > s.length()) {
                throw new IllegalArgumentException("json: bad unicode escape");
              }
              b.append((char) Integer.parseInt(s.substring(pos, pos + 4), 16));
              pos += 4;
              break;
            default:
              throw new IllegalArgumentException("json: bad escape '\\" + e + "'");
          }
        }
        else {
          b.append(c);
        }
      }
    }

    Object number() {
      int start = pos;
      if (peek() == '-') {
        pos++;
      }
      while (pos < s.length() && Character.isDigit(s.charAt(pos))) {
        pos++;
      }
      boolean integral = true;
      if (pos < s.length() && s.charAt(pos) == '.') {
        integral = false;
        pos++;
        while (pos < s.length() && Character.isDigit(s.charAt(pos))) {
          pos++;
        }
      }
      if (pos < s.length() && (s.charAt(pos) == 'e' || s.charAt(pos) == 'E')) {
        integral = false;
        pos++;
        if (pos < s.length() && (s.charAt(pos) == '+' || s.charAt(pos) == '-')) {
          pos++;
        }
        while (pos < s.length() && Character.isDigit(s.charAt(pos))) {
          pos++;
        }
      }
      String num = s.substring(start, pos);
      try {
        if (integral) {
          return Long.parseLong(num);
        }
        return Double.parseDouble(num);
      }
      catch (NumberFormatException e) {
        return Double.parseDouble(num);
      }
    }
  }
}
