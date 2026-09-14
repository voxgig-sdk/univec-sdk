// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/src/Json.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Minimal JSON support for sekreto.
//
// sekreto adds no third-party dependencies, so it carries just enough JSON
// to read a vault's answer and write the CLI's own line of output. It is
// deliberately not a general-purpose library.
//
// A sealed class rather than plain `Any?`: a vault answering `null`, `false`,
// `0` and "no such key" means four different things, and a sealed type keeps
// them apart at compile time rather than by convention. `parse` returns
// `Json?`, where a Kotlin null means "this text is not JSON" and `Json.Null`
// means "this text is the JSON literal null" - a distinction the callers of
// fetchjson need, since only the first is a malformed response.

package KOTLINPACKAGE.feature.secrets.sekreto

import kotlin.math.abs
import kotlin.math.truncate

/** Thrown while reading malformed JSON; never escapes `Json.parse`. */
private class JsonError(message: String) : RuntimeException(message)

sealed class Json {

    object Null : Json()

    data class Bool(val value: Boolean) : Json()

    data class Num(val value: Double) : Json()

    data class Str(val value: String) : Json()

    data class Arr(val value: List<Json>) : Json()

    data class Obj(val value: Map<String, Json>) : Json()

    val asstr: String? get() = (this as? Str)?.value
    val asnum: Double? get() = (this as? Num)?.value
    val asarr: List<Json>? get() = (this as? Arr)?.value
    val asobj: Map<String, Json>? get() = (this as? Obj)?.value

    /** Walk nested objects; null the moment a step is not there. */
    fun dig(vararg keys: String): Json? {
        var at: Json = this

        for (key in keys) {
            at = (at as? Obj)?.value?.get(key) ?: return null
        }

        return at
    }

    /**
     * This value as the text a caller would print, or null when there is no
     * value at all. A JSON null is "no value": every provider here treats it
     * as a miss rather than as the string "null".
     */
    val text: String? get() = when (this) {
        is Null -> null
        is Str -> value
        is Num -> numstr(value)
        is Bool -> if (value) "true" else "false"
        else -> stringify(this)
    }

    companion object {
        fun str(value: String): Json = Str(value)

        fun num(value: Number): Json = Num(value.toDouble())

        fun bool(value: Boolean): Json = Bool(value)

        fun arr(entries: List<Json>): Json = Arr(entries)

        /** An object, in the order given: a payload's field order is signed. */
        fun obj(vararg entries: Pair<String, Json>): Json = Obj(linkedMapOf(*entries))

        /**
         * Parse JSON text. Null for anything unreadable - which the caller
         * must tell apart from a literal `null` body, since only the first
         * means the store could not answer coherently.
         */
        fun parse(text: String?): Json? {
            if (null == text || text.isEmpty()) {
                return null
            }

            return try {
                val reader = Reader(text)
                reader.skip()
                val value = reader.value()
                reader.skip()
                if (!reader.done()) {
                    throw JsonError("sekreto: json: trailing content at ${reader.at}")
                }
                value
            } catch (err: RuntimeException) {
                null
            }
        }

        /** Render a value as compact JSON. */
        fun stringify(value: Json): String {
            val out = StringBuilder()
            write(value, out)
            return out.toString()
        }

        /** Render a string as a JSON string literal, quotes included. */
        fun quote(text: String): String {
            val out = StringBuilder("\"")

            for (ch in text) {
                when (ch) {
                    '"' -> out.append("\\\"")
                    '\\' -> out.append("\\\\")
                    '\n' -> out.append("\\n")
                    '\r' -> out.append("\\r")
                    '\t' -> out.append("\\t")
                    else ->
                        if (0x20 > ch.code) {
                            out.append("\\u%04x".format(ch.code))
                        } else {
                            out.append(ch)
                        }
                }
            }

            return out.append('"').toString()
        }

        private fun write(value: Json, out: StringBuilder) {
            when (value) {
                is Null -> out.append("null")
                is Bool -> out.append(if (value.value) "true" else "false")
                is Num -> out.append(numstr(value.value))
                is Str -> out.append(quote(value.value))
                is Arr -> {
                    out.append('[')
                    value.value.forEachIndexed { index, entry ->
                        if (0 < index) {
                            out.append(',')
                        }
                        write(entry, out)
                    }
                    out.append(']')
                }
                is Obj -> {
                    out.append('{')
                    var first = true
                    for ((key, entry) in value.value) {
                        if (!first) {
                            out.append(',')
                        }
                        first = false
                        out.append(quote(key)).append(':')
                        write(entry, out)
                    }
                    out.append('}')
                }
            }
        }
    }

    private class Reader(val text: String) {
        var at = 0

        fun done(): Boolean = at >= text.length

        fun skip() {
            while (at < text.length && text[at].isWhitespace()) {
                at++
            }
        }

        fun value(): Json {
            if (done()) {
                throw JsonError("sekreto: json: unexpected end")
            }

            return when (text[at]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> Str(str())
                't' -> { word("true"); Bool(true) }
                'f' -> { word("false"); Bool(false) }
                'n' -> { word("null"); Null }
                else -> num()
            }
        }

        fun word(want: String) {
            if (!text.startsWith(want, at)) {
                throw JsonError("sekreto: json: bad literal at $at")
            }
            at += want.length
        }

        fun obj(): Json {
            val out = LinkedHashMap<String, Json>()
            at++ // {

            skip()
            if (!done() && '}' == text[at]) {
                at++
                return Obj(out)
            }

            while (true) {
                skip()
                val key = str()
                skip()

                if (done() || ':' != text[at]) {
                    throw JsonError("sekreto: json: expected ':' at $at")
                }
                at++

                skip()
                out[key] = value()
                skip()

                if (done()) {
                    throw JsonError("sekreto: json: unterminated object")
                }
                if (',' == text[at]) {
                    at++
                    continue
                }
                if ('}' == text[at]) {
                    at++
                    return Obj(out)
                }

                throw JsonError("sekreto: json: expected ',' or '}' at $at")
            }
        }

        fun arr(): Json {
            val out = mutableListOf<Json>()
            at++ // [

            skip()
            if (!done() && ']' == text[at]) {
                at++
                return Arr(out)
            }

            while (true) {
                skip()
                out.add(value())
                skip()

                if (done()) {
                    throw JsonError("sekreto: json: unterminated array")
                }
                if (',' == text[at]) {
                    at++
                    continue
                }
                if (']' == text[at]) {
                    at++
                    return Arr(out)
                }

                throw JsonError("sekreto: json: expected ',' or ']' at $at")
            }
        }

        fun str(): String {
            if (done() || '"' != text[at]) {
                throw JsonError("sekreto: json: expected string at $at")
            }
            at++

            val out = StringBuilder()

            while (at < text.length) {
                val ch = text[at++]

                if ('"' == ch) {
                    return out.toString()
                }

                if ('\\' != ch) {
                    out.append(ch)
                    continue
                }

                if (done()) {
                    break
                }

                when (val escape = text[at++]) {
                    '"' -> out.append('"')
                    '\\' -> out.append('\\')
                    '/' -> out.append('/')
                    'b' -> out.append('\b')
                    'f' -> out.append('')
                    'n' -> out.append('\n')
                    'r' -> out.append('\r')
                    't' -> out.append('\t')
                    'u' -> {
                        if (at + 4 > text.length) {
                            throw JsonError("sekreto: json: bad unicode escape")
                        }
                        out.append(text.substring(at, at + 4).toInt(16).toChar())
                        at += 4
                    }
                    else -> throw JsonError("sekreto: json: bad escape [$escape] at $at")
                }
            }

            throw JsonError("sekreto: json: unterminated string")
        }

        fun num(): Json {
            val start = at

            if (at < text.length && ('-' == text[at] || '+' == text[at])) {
                at++
            }

            while (at < text.length) {
                val ch = text[at]
                if (ch.isDigit() || '.' == ch || 'e' == ch || 'E' == ch || '-' == ch || '+' == ch) {
                    at++
                } else {
                    break
                }
            }

            val span = text.substring(start, at)

            return Num(
                span.toDoubleOrNull()
                    ?: throw JsonError("sekreto: json: bad number [$span] at $start"),
            )
        }
    }
}

/**
 * Render a number the way every other port does: a whole number has no
 * fractional tail, so a JSON `1` read back and printed stays `1`.
 */
internal fun numstr(value: Double): String {
    if (value.isNaN() || value.isInfinite()) {
        return "null"
    }

    if (value == truncate(value) && 9007199254740992.0 > abs(value)) {
        return value.toLong().toString()
    }

    return value.toString()
}
