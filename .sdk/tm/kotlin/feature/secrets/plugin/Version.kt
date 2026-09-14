// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Version.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.math.BigInteger

/**
 * Versions and ranges (section 11.2).
 *
 * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
 * version. A requirement declares `range`. A requirement is satisfied when
 * the names match, the `match` passes, and the provider's `version` falls
 * inside the requirement's `range`.
 *
 * That is the whole rule. There is no third field and no second comparison -
 * an earlier draft added a provider-side `compat` range, which left three
 * values and no statement of how they combine, and three defensible readings
 * of one declaration is worse than the ambiguity it was introduced to fix.
 */
object Version {

    private val VERSION_RE = Regex("(\\d+)(?:\\.(\\d+))?(?:\\.(\\d+))?")

    /**
     * A COMPONENT IS BOUNDED, and the bound is the model's, not the host
     * language's. A kotlin `Long` is 64-bit and javascript stops being exact
     * past 2**53, so `9223372036854775808.0.0` parsed to an exact value here
     * and a rounded one there. 2**31-1 is the smallest bound every target
     * language holds exactly, which makes it the model's.
     */
    const val COMPONENT_MAX = 2147483647

    /**
     * `BigInteger`, not `toInt()`: a component of forty digits overflows
     * silently, and the check below would then pass for a value plainly out
     * of range.
     */
    private fun component(digits: String, whole: String, field: String): Double {
        val value = BigInteger(digits)
        if (BigInteger.valueOf(COMPONENT_MAX.toLong()) < value) {
            Types.fail(
                "plugin_bad_range",
                "version component out of range in $whole: $digits",
                mapOf(field to whole)
            )
        }
        return value.toDouble()
    }

    /**
     * Two forms and no more (section 11.2):
     *
     *   '2.1'    >= 2.1.0 and < 3.0.0
     *   '~2.1'   >= 2.1.0 and < 2.2.0
     */
    fun parseRange(range: Any?): Map<String, Any?> {
        if (range !is String || "" == range) {
            Types.fail("plugin_bad_range", "invalid range: $range", mapOf("range" to range))
        }
        val tilde = range.startsWith("~")
        val body = if (tilde) range.substring(1) else range
        val m = VERSION_RE.matchEntire(body)
            ?: Types.fail("plugin_bad_range", "invalid range: $range", mapOf("range" to range))

        val major = component(m.groupValues[1], range, "range")
        val minor = if ("" == m.groupValues[2]) 0.0 else component(m.groupValues[2], range, "range")
        val patch = if ("" == m.groupValues[3]) 0.0 else component(m.groupValues[3], range, "range")

        val out = java.util.TreeMap<String, Any?>()
        out["lo"] = listOf(major, minor, patch)
        // `major + 1` on a COMPONENT_MAX major is 2147483648, which an `Int`
        // cannot hold - it wraps to the negative bound, and
        // `version/range#component-max` is the entry that says so. Every number
        // in this port is a `Double` for the model's reason; here it is also
        // the arithmetic's.
        out["hi"] = if (tilde) listOf(major, minor + 1, 0.0) else listOf(major + 1, 0.0, 0.0)
        return out
    }

    fun parseVersion(version: Any?): List<Double> {
        if (version !is String) {
            Types.fail("plugin_bad_range", "invalid version: $version", mapOf("version" to version))
        }
        val m = VERSION_RE.matchEntire(version)
            ?: Types.fail(
                "plugin_bad_range", "invalid version: $version",
                mapOf("version" to version)
            )
        return listOf(
            component(m.groupValues[1], version, "version"),
            if ("" == m.groupValues[2]) 0.0 else component(m.groupValues[2], version, "version"),
            if ("" == m.groupValues[3]) 0.0 else component(m.groupValues[3], version, "version")
        )
    }

    fun versionCmp(a: List<Double>, b: List<Double>): Int {
        for (i in 0 until 3) {
            val x = if (i < a.size) a[i] else 0.0
            val y = if (i < b.size) b[i] else 0.0
            if (x != y) return if (x < y) -1 else 1
        }
        return 0
    }

    /** The one satisfaction predicate: lo <= version < hi. */
    fun satisfies(version: Any?, range: Any?): Boolean {
        val v = parseVersion(version)
        val r = parseRange(range)
        @Suppress("UNCHECKED_CAST")
        return 0 <= versionCmp(v, r["lo"] as List<Double>) &&
            0 > versionCmp(v, r["hi"] as List<Double>)
    }

    /**
     * `satisfies` for the internal callers that treat an unparseable version
     * or range as "does not satisfy" - Capability and Graph, both of which
     * run over data the corpus has already admitted.
     */
    fun satisfiesq(version: Any?, range: Any?): Boolean = try {
        satisfies(version, range)
    } catch (e: PluginError) {
        false
    }

    /** The numeric parts of a version, or zeros - a SORT KEY, never a check. */
    fun versionParts(text: String): List<Double> = try {
        parseVersion(text)
    } catch (e: PluginError) {
        listOf(0.0, 0.0, 0.0)
    }
}
