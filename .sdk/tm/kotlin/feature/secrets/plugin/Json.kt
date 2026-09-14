// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Json.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.util.TreeMap

/**
 * The JSON parser and writer, and the only ones this port has.
 *
 * NO JACKSON, NO GSON, NO KOTLINX.SERIALIZATION, NO JUNIT (section 16). The
 * library is allowed exactly one runtime dependency, `voxgig/struct`, which
 * has no kotlin port; everything else is the kotlin stdlib and the JDK.
 * Parsing the corpus is a hundred and fifty lines, and a hundred and fifty
 * lines is cheaper than a gradle `dependencies` block every embedding host
 * inherits - and it keeps this port buildable by `kotlinc` alone.
 */
object Json {

    fun parse(text: String): Any? {
        val parser = Parser(text)
        parser.skipws()
        val value = parser.value()
        parser.skipws()
        if (parser.at < parser.chars.size) {
            throw IllegalArgumentException("trailing input at ${parser.at}")
        }
        return value
    }

    /** Compact JSON, map keys in sorted order (which a `TreeMap` already is). */
    fun write(value: Any?): String {
        val out = StringBuilder()
        writeTo(value, out)
        return out.toString()
    }

    private fun writeTo(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Boolean -> out.append(if (value) "true" else "false")
            is Double -> out.append(writeNumber(value))
            is Int -> out.append(value.toString())
            is String -> writeString(value, out)
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { i, v ->
                    if (0 < i) out.append(',')
                    writeTo(v, out)
                }
                out.append(']')
            }
            is Map<*, *> -> {
                out.append('{')
                Types.keys(value).forEachIndexed { i, k ->
                    if (0 < i) out.append(',')
                    writeString(k, out)
                    out.append(':')
                    writeTo(value[k], out)
                }
                out.append('}')
            }
            // Anything the model has no JSON spelling for - a host, an
            // instance handle, a callback the driver exported.
            else -> out.append("\"(opaque)\"")
        }
    }

    /**
     * A whole double renders WITHOUT its fraction, so `1.0` and `1` spell the
     * same. Every number in this port is a `Double`, so without this every
     * message and every encoded expectation would read `1.0` where the
     * corpus wrote `1`.
     */
    private fun writeNumber(value: Double): String =
        if (value == Math.floor(value) && !value.isInfinite()) {
            value.toLong().toString()
        } else {
            value.toString()
        }

    private fun writeString(value: String, out: StringBuilder) {
        out.append('"')
        for (c in value) {
            when {
                '"' == c -> out.append("\\\"")
                CHAR_BACKSLASH == c -> out.append("\\\\")
                CHAR_NEWLINE == c -> out.append("\\n")
                CHAR_RETURN == c -> out.append("\\r")
                CHAR_TAB == c -> out.append("\\t")
                c < CHAR_SPACE -> out.append("\\u%04x".format(codeOf(c)))
                else -> out.append(c)
            }
        }
        out.append('"')
    }

    // `Char.code` is Kotlin 1.5+ and does not resolve on the 1.3.31 ubuntu
    // ships to CI; `Char.toInt()` is deprecated from 1.5 and the Makefile
    // builds -Werror. `Char.minus(Char)` has been Int since 1.0 and is
    // deprecated in neither, so it is the one spelling both compilers take.
    private fun codeOf(c: Char): Int = c - '\u0000'

    private const val CHAR_SPACE = '\u0020'

    private const val CHAR_BACKSLASH = '\u005C'
    private const val CHAR_NEWLINE = '\u000A'
    private const val CHAR_RETURN = '\u000D'
    private const val CHAR_TAB = '\u0009'
    private const val CHAR_BACKSPACE = '\u0008'
    private const val CHAR_FORMFEED = '\u000C'

    private class Parser(text: String) {
        val chars: CharArray = text.toCharArray()
        var at: Int = 0

        fun skipws() {
            while (at < chars.size &&
                (' ' == chars[at] || CHAR_TAB == chars[at] ||
                    CHAR_NEWLINE == chars[at] || CHAR_RETURN == chars[at])
            ) {
                at++
            }
        }

        fun value(): Any? = when (chars[at]) {
            '{' -> map()
            '[' -> list()
            '"' -> string()
            't' -> literal("true", true)
            'f' -> literal("false", false)
            'n' -> literal("null", null)
            else -> number()
        }

        fun literal(word: String, value: Any?): Any? {
            if (at + word.length > chars.size ||
                String(chars, at, word.length) != word
            ) {
                throw IllegalArgumentException("unexpected input at $at")
            }
            at += word.length
            return value
        }

        fun map(): Map<String, Any?> {
            val out = TreeMap<String, Any?>()
            at++
            skipws()
            if ('}' == chars[at]) {
                at++
                return out
            }
            while (true) {
                skipws()
                val key = string()
                skipws()
                if (':' != chars[at]) throw IllegalArgumentException("expected : at $at")
                at++
                skipws()
                out[key] = value()
                skipws()
                if (',' == chars[at]) {
                    at++
                    continue
                }
                if ('}' != chars[at]) throw IllegalArgumentException("expected } at $at")
                at++
                return out
            }
        }

        fun list(): List<Any?> {
            val out = ArrayList<Any?>()
            at++
            skipws()
            if (']' == chars[at]) {
                at++
                return out
            }
            while (true) {
                skipws()
                out.add(value())
                skipws()
                if (',' == chars[at]) {
                    at++
                    continue
                }
                if (']' != chars[at]) throw IllegalArgumentException("expected ] at $at")
                at++
                return out
            }
        }

        fun string(): String {
            if ('"' != chars[at]) throw IllegalArgumentException("expected string at $at")
            at++
            val out = StringBuilder()
            while (true) {
                if (at >= chars.size) throw IllegalArgumentException("unterminated string")
                val c = chars[at]
                if ('"' == c) {
                    at++
                    return out.toString()
                }
                if (CHAR_BACKSLASH == c) {
                    at++
                    val e = chars[at]
                    when (e) {
                        'n' -> out.append(CHAR_NEWLINE)
                        't' -> out.append(CHAR_TAB)
                        'r' -> out.append(CHAR_RETURN)
                        'b' -> out.append(CHAR_BACKSPACE)
                        'f' -> out.append(CHAR_FORMFEED)
                        'u' -> {
                            out.append(String(chars, at + 1, 4).toInt(16).toChar())
                            at += 4
                        }
                        else -> out.append(e)
                    }
                    at++
                    continue
                }
                out.append(c)
                at++
            }
        }

        fun number(): Double {
            val start = at
            while (at < chars.size &&
                (chars[at].isDigit() || '-' == chars[at] || '+' == chars[at] ||
                    '.' == chars[at] || 'e' == chars[at] || 'E' == chars[at])
            ) {
                at++
            }
            if (start == at) throw IllegalArgumentException("unexpected input at $at")
            return String(chars, start, at - start).toDouble()
        }
    }
}
