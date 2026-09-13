// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Json.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** The JSON parser.
  *
  * A hundred and fifty lines, and a hundred and fifty lines is cheaper than a
  * `libraryDependencies` line every embedding host inherits - and it keeps this
  * port buildable by `scalac` alone, with no sbt and no resolver.
  */
object Json {

  def parse(text: String): Value = {
    val parser = new Parser(text)
    parser.skipws()
    val value = parser.value()
    parser.skipws()
    if (parser.at < parser.chars.length) {
      Types.fail("plugin_json", "trailing input at " + parser.at)
    }
    value
  }

  private class Parser(text: String) {
    val chars: Array[Char] = text.toCharArray
    var at: Int = 0

    def skipws(): Unit =
      while (at < chars.length &&
        (chars(at) == ' ' || chars(at) == '\t' ||
          chars(at) == '\n' || chars(at) == '\r')) {
        at += 1
      }

    def value(): Value = {
      if (at >= chars.length) Types.fail("plugin_json", "unexpected end of input")
      chars(at) match {
        case '{'  => map()
        case '['  => list()
        case '"'  => VStr(string())
        case 't'  => literal("true", VBool(true))
        case 'f'  => literal("false", VBool(false))
        case 'n'  => literal("null", VNull)
        case _    => number()
      }
    }

    def literal(word: String, out: Value): Value = {
      if (at + word.length > chars.length ||
        new String(chars, at, word.length) != word) {
        Types.fail("plugin_json", "unexpected input at " + at)
      }
      at += word.length
      out
    }

    def map(): Value = {
      var out = Map.empty[String, Value]
      at += 1
      skipws()
      if (chars(at) == '}') {
        at += 1
        return VMap(out)
      }
      var done = false
      while (!done) {
        skipws()
        val key = string()
        skipws()
        if (chars(at) != ':') Types.fail("plugin_json", "expected : at " + at)
        at += 1
        skipws()
        out = out + (key -> value())
        skipws()
        if (chars(at) == ',') {
          at += 1
        } else if (chars(at) == '}') {
          at += 1
          done = true
        } else {
          Types.fail("plugin_json", "expected } at " + at)
        }
      }
      VMap(out)
    }

    def list(): Value = {
      val out = List.newBuilder[Value]
      at += 1
      skipws()
      if (chars(at) == ']') {
        at += 1
        return VList(Nil)
      }
      var done = false
      while (!done) {
        skipws()
        out += value()
        skipws()
        if (chars(at) == ',') {
          at += 1
        } else if (chars(at) == ']') {
          at += 1
          done = true
        } else {
          Types.fail("plugin_json", "expected ] at " + at)
        }
      }
      VList(out.result())
    }

    def string(): String = {
      if (chars(at) != '"') Types.fail("plugin_json", "expected string at " + at)
      at += 1
      val out = new StringBuilder
      var done = false
      while (!done) {
        if (at >= chars.length) Types.fail("plugin_json", "unterminated string")
        val c = chars(at)
        if (c == '"') {
          at += 1
          done = true
        } else if (c == '\\') {
          at += 1
          chars(at) match {
            case 'n' => out.append('\n')
            case 't' => out.append('\t')
            case 'r' => out.append('\r')
            case 'b' => out.append('\b')
            case 'f' => out.append('\f')
            case 'u' =>
              out.append(Integer.parseInt(new String(chars, at + 1, 4), 16).toChar)
              at += 4
            case e => out.append(e)
          }
          at += 1
        } else {
          out.append(c)
          at += 1
        }
      }
      out.toString
    }

    def number(): Value = {
      val start = at
      while (at < chars.length && isNumeric(chars(at))) at += 1
      if (start == at) Types.fail("plugin_json", "unexpected input at " + at)
      VNum(new String(chars, start, at - start).toDouble)
    }

    def isNumeric(c: Char): Boolean =
      c.isDigit || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'
  }
}
