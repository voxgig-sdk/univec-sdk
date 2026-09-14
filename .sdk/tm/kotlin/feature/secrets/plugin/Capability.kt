// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Capability.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Capabilities (section 11.1).
 *
 * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a dependency
 * on something that can do the job, and which instance is doing it is
 * exactly the configuration detail a plugin must not care about.
 *
 * But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains.
 */
object Capability {

    /**
     * Rank the matching live providers and return them best-first: highest
     * `version`, then LOWEST `priority` (default 0), then declaration
     * position `pos` ascending.
     *
     * `priority` is a field on the capability rather than section 7's `order`
     * band, because bands live on POINT BINDINGS: a provider may have several
     * bindings with different bands, or none at all, so a rank reaching for
     * one would be undefined in the common case.
     *
     * Without a total rank, "any provider satisfies" is true of the GRAPH and
     * useless to the PLUGIN - two ports could bind different `store`
     * instances, both resolve green, and behave differently, which is
     * precisely the divergence a shared corpus exists to catch.
     */
    fun resolveCapability(req: Any?, candidates: Any?): List<Any?> {
        val hits = (candidates as List<*>)
            .filter { matches(req, Types.get(it, "provides") ?: emptyMap<String, Any?>()) }
        return Types.stableSortBy(hits) { rankKey(it) }
    }

    /**
     * An ABSENT version sorts LAST, whatever the other is - "no version"
     * loses to every version rather than being read as 0.0.0. The leading
     * flag is what expresses that in a sort KEY rather than a comparator.
     */
    fun rankKey(cand: Any?): List<Any> {
        val prov = Types.get(cand, "provides") ?: emptyMap<String, Any?>()
        val version = Types.get(prov, "version")
        return listOf(
            if (null == version) 1.0 else 0.0,
            if (null == version) listOf(0.0, 0.0, 0.0)
            else Version.versionParts(version as String).map { -it },
            asDouble(Types.get(prov, "priority")),
            asDouble(Types.get(cand, "pos"))
        )
    }

    private fun asDouble(v: Any?): Double = when (v) {
        is Double -> v
        is Int -> v.toDouble()
        else -> 0.0
    }

    fun matches(req: Any?, prov: Any?): Boolean {
        if (Types.get(req, "name") != Types.get(prov, "name")) return false

        if (null != Types.get(req, "range")) {
            if (null == Types.get(prov, "version")) return false
            if (!Version.satisfiesq(Types.get(prov, "version"), Types.get(req, "range"))) {
                return false
            }
        }

        // `match` is checked against the provider's `attrs`, key by key. A key
        // the provider does not carry is a miss, not a pass: a requirement
        // asking for `transactional: true` must not be satisfied by a provider
        // that never said.
        val want = Types.get(req, "match")
        if (null != want) {
            val attrs = Types.get(prov, "attrs") ?: emptyMap<String, Any?>()
            for (k in Types.keys(want)) {
                if (!Types.has(attrs, k)) return false
                if (!matchValue(Types.get(want, k), Types.get(attrs, k))) return false
            }
        }
        return true
    }

    /**
     * PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
     *
     * Every leaf in the requirement must be present and equal in the
     * capability, keys not mentioned are not checked. Equality is by JSON
     * TYPE as well as value: `transactional: 1` does not satisfy
     * `transactional: true`. KOTLIN NEEDS NO GUARD FOR THAT - `true == 1` is
     * false for `Any?`, because `Boolean` and `Double` are unrelated classes
     * with no coercion. Python, PHP, Perl and Lua all need one, and
     * `capability/match` pins the behaviour for every port rather than
     * trusting each language's equality.
     *
     * A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
     */
    fun matchValue(want: Any?, got: Any?): Boolean {
        if (want is Map<*, *>) {
            if (got !is Map<*, *>) return false
            for (k in Types.keys(want)) {
                if (!got.containsKey(k)) return false
                if (!matchValue(want[k], got[k])) return false
            }
            return true
        }
        if (want is List<*>) {
            if (got !is List<*> || want.size != got.size) return false
            return want.indices.all { matchValue(want[it], got[it]) }
        }
        return Types.same(want, got)
    }
}
