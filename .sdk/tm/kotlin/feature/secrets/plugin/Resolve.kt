// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Resolve.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Dynamic resolution (section 10.2) - name to candidate module ids.
 *
 * PURE. It returns the ids a host WOULD try, in order; it does not load
 * anything. That separation is what lets the corpus pin resolution in every
 * language including those with no dynamic loading at all, and it is why
 * section 15.4 puts real module loading in per-port integration tests rather
 * than here.
 */
object Resolve {

    val defaultSources: List<Any?> = listOf(
        mapOf(
            "kind" to "module",
            "prefix" to listOf("@voxgig/plugin-", "voxgig-plugin-", "plugin-", "")
        )
    )

    @JvmOverloads
    fun resolveCandidates(name: String, sources: Any? = null): List<String> {
        // A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing`
        // is already a package id; prefixing it produces
        // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
        if (name.startsWith("@")) return listOf(name)

        val list = if (sources is List<*> && sources.isNotEmpty()) sources else defaultSources
        val out = ArrayList<String>()

        for (src in list) {
            when (Types.get(src, "kind")) {
                "module" -> {
                    val declared = Types.get(src, "prefix")
                    val prefixes = if (declared is List<*> && declared.isNotEmpty()) {
                        declared
                    } else {
                        listOf("")
                    }
                    for (p in prefixes) {
                        val id = "$p$name"
                        if (!out.contains(id)) out.add(id)
                    }
                }
                "path" -> {
                    val dir = (Types.get(src, "dir") as String).trimEnd('/')
                    val id = "$dir/$name"
                    if (!out.contains(id)) out.add(id)
                }
            }
        }
        return out
    }

    /**
     * A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a
     * name with a letter or `@`, so `./local/thing` is not a ref and never
     * reaches candidate generation - seneca allows a path where a plugin name
     * goes, and this design deliberately does not, because a ref is an
     * ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
     */
    fun resolveFrom(from: Any?): List<Any?> = listOf(from)
}
