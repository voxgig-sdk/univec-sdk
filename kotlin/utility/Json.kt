package voxgig.univecsdk.utility

/**
 * Minimal zero-dependency JSON parser for the Univec SDK runtime.
 * Produces the same shapes the rest of the runtime consumes:
 * LinkedHashMap<String, Any?>, ArrayList<Any?>, String, Long (integer-valued
 * numbers), Double, Boolean and null.
 *
 * Serialization is handled by the vendored Struct.jsonify; this class only
 * parses. [parse] throws IllegalArgumentException on malformed input;
 * [parseOrNull] returns null instead (used by the HTTP fetcher for non-JSON
 * bodies).
 */
object Json {

  fun parse(src: String?): Any? {
    if (src == null) {
      throw IllegalArgumentException("json: null input")
    }
    val p = Parser(src)
    p.ws()
    val out = p.value()
    p.ws()
    if (!p.done()) {
      throw IllegalArgumentException("json: trailing content at " + p.pos)
    }
    return out
  }

  fun parseOrNull(src: String?): Any? {
    return try {
      parse(src)
    } catch (e: RuntimeException) {
      null
    }
  }

  private class Parser(val s: String) {
    var pos: Int = 0

    fun done(): Boolean {
      return pos >= s.length
    }

    fun ws() {
      while (pos < s.length) {
        val c = s[pos]
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
          pos++
        } else {
          break
        }
      }
    }

    fun peek(): Char {
      if (pos >= s.length) {
        throw IllegalArgumentException("json: unexpected end of input")
      }
      return s[pos]
    }

    fun expect(c: Char) {
      if (peek() != c) {
        throw IllegalArgumentException("json: expected '$c' at $pos, got '${peek()}'")
      }
      pos++
    }

    fun value(): Any? {
      val c = peek()
      return when (c) {
        '{' -> obj()
        '[' -> array()
        '"' -> string()
        't' -> {
          literal("true")
          true
        }
        'f' -> {
          literal("false")
          false
        }
        'n' -> {
          literal("null")
          null
        }
        else -> {
          if (c == '-' || (c in '0'..'9')) {
            number()
          } else {
            throw IllegalArgumentException("json: unexpected '$c' at $pos")
          }
        }
      }
    }

    fun literal(lit: String) {
      if (!s.startsWith(lit, pos)) {
        throw IllegalArgumentException("json: invalid literal at $pos")
      }
      pos += lit.length
    }

    fun obj(): MutableMap<String, Any?> {
      expect('{')
      val out = linkedMapOf<String, Any?>()
      ws()
      if (peek() == '}') {
        pos++
        return out
      }
      while (true) {
        ws()
        val key = string()
        ws()
        expect(':')
        ws()
        out[key] = value()
        ws()
        val c = peek()
        if (c == ',') {
          pos++
          continue
        }
        if (c == '}') {
          pos++
          return out
        }
        throw IllegalArgumentException("json: expected ',' or '}' at $pos")
      }
    }

    fun array(): MutableList<Any?> {
      expect('[')
      val out = mutableListOf<Any?>()
      ws()
      if (peek() == ']') {
        pos++
        return out
      }
      while (true) {
        ws()
        out.add(value())
        ws()
        val c = peek()
        if (c == ',') {
          pos++
          continue
        }
        if (c == ']') {
          pos++
          return out
        }
        throw IllegalArgumentException("json: expected ',' or ']' at $pos")
      }
    }

    fun string(): String {
      expect('"')
      val b = StringBuilder()
      while (true) {
        if (pos >= s.length) {
          throw IllegalArgumentException("json: unterminated string")
        }
        val c = s[pos++]
        if (c == '"') {
          return b.toString()
        }
        if (c == '\\') {
          if (pos >= s.length) {
            throw IllegalArgumentException("json: unterminated escape")
          }
          val e = s[pos++]
          when (e) {
            '"' -> b.append('"')
            '\\' -> b.append('\\')
            '/' -> b.append('/')
            'b' -> b.append('\b')
            'f' -> b.append('\u000C')
            'n' -> b.append('\n')
            'r' -> b.append('\r')
            't' -> b.append('\t')
            'u' -> {
              if (pos + 4 > s.length) {
                throw IllegalArgumentException("json: bad unicode escape")
              }
              b.append(s.substring(pos, pos + 4).toInt(16).toChar())
              pos += 4
            }
            else -> throw IllegalArgumentException("json: bad escape '\\$e'")
          }
        } else {
          b.append(c)
        }
      }
    }

    fun number(): Any {
      val start = pos
      if (peek() == '-') {
        pos++
      }
      while (pos < s.length && s[pos].isDigit()) {
        pos++
      }
      var integral = true
      if (pos < s.length && s[pos] == '.') {
        integral = false
        pos++
        while (pos < s.length && s[pos].isDigit()) {
          pos++
        }
      }
      if (pos < s.length && (s[pos] == 'e' || s[pos] == 'E')) {
        integral = false
        pos++
        if (pos < s.length && (s[pos] == '+' || s[pos] == '-')) {
          pos++
        }
        while (pos < s.length && s[pos].isDigit()) {
          pos++
        }
      }
      val num = s.substring(start, pos)
      return try {
        if (integral) {
          num.toLong()
        } else {
          num.toDouble()
        }
      } catch (e: NumberFormatException) {
        num.toDouble()
      }
    }
  }
}
