// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Types.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * The value model, the error type, and the JSON writer.
 *
 * THE VALUE MODEL IS `Any?`, and each JSON type has ONE kotlin spelling:
 * `null`, [Boolean], [Double], [String], `List<Any?>`, `Map<String, Any?>`.
 * A map is always a [java.util.TreeMap] - every port has to sort its keys
 * before iterating, and a sorted map makes that the default rather than a
 * discipline to remember.
 *
 * A NUMBER IS ALWAYS A `Double`, because JSON has one number type and the
 * canonical is javascript. A `Long` anywhere in this data would compare
 * unequal to the `Double` the parser produced for the same literal -
 * `1L == 1.0` is false for `Any?` in kotlin, exactly as
 * `Integer.valueOf(1).equals(Double.valueOf(1))` is in java - and the
 * corpus would fail on a distinction the model does not have.
 */
object Types {

    /** Section 5.1's seven statuses, and no more. */
    val statuses = listOf(
        "declared", "loaded", "pending", "live", "failed", "loading", "closing"
    )

    /**
     * Section 12's detail keys, in the order a message renders them. FIXED,
     * not the map's: a message is a searchable log line, and a line whose
     * fields move between runs is not.
     */
    val detailOrder = listOf(
        "ref", "point", "name", "key", "spec", "refs", "kind", "directive",
        "cycle", "holders", "cause"
    )

    /** The value at a key, or null. Absence and null read the same here. */
    fun get(m: Any?, k: String): Any? = if (m is Map<*, *>) m[k] else null

    /** PRESENCE, which is what distinguishes an authored null from absence. */
    fun has(m: Any?, k: String): Boolean = m is Map<*, *> && m.containsKey(k)

    /**
     * The keys of a map, SORTED - every walk of a map goes through here. A
     * `TreeMap` is already in this order, and this is what says so at the
     * call site rather than relying on the caller knowing the type.
     */
    fun keys(m: Any?): List<String> =
        if (m is Map<*, *>) m.keys.map { it as String }.sorted() else emptyList()

    /**
     * JSON truthiness: null and false, and nothing else, are false. Kotlin
     * has no truthiness of its own - `if (0)` does not compile - so this is
     * where the model's rule is written down.
     */
    fun truthy(v: Any?): Boolean = !(null == v || false == v)

    /**
     * An INTEGER, and only when the value is one. Section 7's band is an
     * integer the document wrote as one, and every number here is a
     * `Double`, so the test is "a whole double" - `true` and `"2"` are not
     * bands and neither reaches this.
     */
    fun asInt(v: Any?): Int? = when {
        v is Double && v == Math.floor(v) && !v.isInfinite() -> v.toInt()
        v is Int -> v
        else -> null
    }

    /**
     * A STABLE sort by a comparable key.
     *
     * Kotlin's `sortedWith` delegates to `java.util.Arrays.sort` on an
     * object array, which is a TimSort and documented stable. Stability is
     * load-bearing: section 7's comparators fall through to a `pos` or ref
     * tie-break that javascript's stable sort resolves BY POSITION, and a
     * port that shuffled equal keys would order a teardown differently
     * between two runs of one process. The name is kept so that one place
     * in the port says so.
     */
    fun <T> stableSortBy(list: List<T>, keyOf: (T) -> List<Any>): List<T> =
        // `Comparator { }` and not a bare lambda: SAM conversion for a
        // KOTLIN functional interface arrived in 1.4, and this port targets
        // the 1.3 compiler. `java.util.Comparator` converts in every version.
        list.sortedWith(Comparator { a: T, b: T -> compareKeys(keyOf(a), keyOf(b)) })

    /**
     * Compare two sort keys element by element. A key is a list of numbers,
     * strings and nested lists, which is what lets `rankKey` express "absent
     * version sorts last" as a leading flag rather than as a comparator.
     */
    @Suppress("UNCHECKED_CAST")
    fun compareKeys(a: List<Any>, b: List<Any>): Int {
        for (i in 0 until minOf(a.size, b.size)) {
            val x = a[i]
            val y = b[i]
            val c = if (x is List<*> && y is List<*>) {
                compareKeys(x as List<Any>, y as List<Any>)
            } else {
                (x as Comparable<Any>).compareTo(y)
            }
            if (0 != c) return c
        }
        return a.size.compareTo(b.size)
    }

    /**
     * JSON equality: same type, then same value.
     *
     * `true == 1` is false in kotlin for `Any?`, so the bool guard the
     * dynamic ports need is not required here. Every number is a `Double`,
     * so the `1` versus `1.0` question the model does not have never arises.
     */
    fun same(a: Any?, b: Any?): Boolean {
        if (a is Map<*, *> && b is Map<*, *>) {
            if (a.size != b.size) return false
            return a.all { (k, v) -> b.containsKey(k) && same(v, b[k]) }
        }
        if (a is List<*> || b is List<*>) {
            if (a !is List<*> || b !is List<*> || a.size != b.size) return false
            return a.indices.all { same(a[it], b[it]) }
        }
        if (a is Map<*, *> || b is Map<*, *>) return false
        return a == b
    }

    /**
     * `plugin/<code>: <text> [<key>=<value> ...]`
     *
     * Values render as COMPACT JSON, so a value containing a space or a
     * bracket cannot break the parse, and a list renders as a JSON array.
     * The bracket is absent entirely when no field applies.
     */
    fun formatError(code: String, text: String, details: Map<String, Any?>): String {
        val parts = detailOrder.filter { details.containsKey(it) }
            .map { "$it=${Json.write(details[it])}" }
        val tail = if (parts.isEmpty()) "" else " [${parts.joinToString(" ")}]"
        return "plugin/$code: $text$tail"
    }

    /**
     * Throw a section 12 error. One spelling, so every raise site reads the
     * same. `Nothing` is the return type, so the compiler knows a call is a
     * terminator and no caller needs a redundant `return` after one.
     */
    fun fail(code: String, text: String, details: Map<String, Any?> = emptyMap()): Nothing =
        throw PluginError(code, text, details)

    /**
     * The section 12 code of an error, or "" for one this library did not
     * throw. The corpus compares by code, so the driver needs one place that
     * knows how to read it.
     */
    fun codeOf(e: Throwable): String = if (e is PluginError) e.code else ""

    fun messageOf(e: Throwable): String = e.message ?: e.toString()
}

/**
 * Every error carries a section 12 code. Ports compare by CODE and never by
 * message: wording is a port's own business, and pinning the words would
 * make every translation a corpus change. The FORMAT, however, is pinned - a
 * parseable message is what makes a log searchable across twenty languages.
 */
class PluginError(
    val code: String,
    val text: String,
    val details: Map<String, Any?>
) : RuntimeException(Types.formatError(code, text, details))
