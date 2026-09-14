// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Export.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Exports (section 11).
 *
 * An instance publishes values for other plugins and for the application.
 * Read with `host.exports("retry$fast/client")`.
 *
 * THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves to
 * the UNTAGGED instance if one exists; if not, and exactly one tagged
 * instance exports that key, it resolves to that one; if two do, it is
 * `plugin_export_ambiguous` - deliberately diverging from seneca's silent
 * last-wins, because with multi-instance as a headline feature an ambiguous
 * alias is a defect waiting for production.
 */
object Export {

    /** One published value. An internal shape, never a corpus value. */
    data class Exported(val ref: String, val key: String, val value: Any?)

    fun resolveExport(spec: String, exported: List<Exported>): Any? {
        val cut = spec.indexOf('/')
        if (0 > cut) {
            Types.fail(
                "plugin_export_ambiguous", "export spec needs a key: $spec",
                mapOf("spec" to spec)
            )
        }
        val head = spec.substring(0, cut)
        val key = spec.substring(cut + 1)

        // A fully qualified ref: exactly one answer or none.
        val want = Refs.canon(head)
        for (e in exported) {
            if (e.ref == want && e.key == key) return e.value
        }

        // An alias: the name, not a ref. Look at every instance of it.
        val byname = exported.filter { Refs.refName(it.ref) == head && it.key == key }
        if (byname.isEmpty()) return null

        for (e in byname) {
            if ("" == Refs.parseRef(e.ref)["tag"]) return e.value
        }
        if (1 == byname.size) return byname[0].value

        val refs = byname.map { it.ref }.sorted()
        Types.fail(
            "plugin_export_ambiguous",
            "alias $spec matches ${refs.size} instances: ${refs.joinToString(", ")}",
            mapOf("spec" to spec, "refs" to refs)
        )
    }
}
