// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Plugin.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * The canonical surface `make parity` checks (AGENTS.md section 4). Small on
 * purpose (section 19): everything else is methods on the host and instance
 * types, because a library that grows a second public entry point per feature
 * is a library twenty ports pay for twice.
 *
 * ELEVEN NAMES, AND THEY FORWARD. The implementation lives in the object named
 * for its design section, so a reader who arrives at `resolveOrder` from the
 * corpus lands in `Order` where section 7 is quoted.
 */
object Plugin {

    // host construction
    @JvmStatic
    @JvmOverloads
    fun makeHost(options: Any? = null): Host = Host(options)

    @JvmStatic
    @JvmOverloads
    fun makeCatalog(definitions: List<Any?>? = null): Catalog {
        val catalog = Catalog()
        for (d in definitions ?: emptyList()) catalog.add(d)
        return catalog
    }

    // refs - the first thing a new port implements (section 4)
    @JvmStatic
    fun parseRef(str: Any?): Map<String, Any?> = Refs.parseRef(str)

    @JvmStatic
    @JvmOverloads
    fun formatRef(name: Any?, tag: Any? = null): String = Refs.formatRef(name, tag)

    @JvmStatic
    fun checkName(name: Any?): Boolean = Refs.checkName(name)

    @JvmStatic
    fun checkTag(tag: Any?): Boolean = Refs.checkTag(tag)

    // pure functions over documents and definitions
    @JvmStatic
    fun normalizeConfig(input: Any?): Map<String, Any?> = Config.normalizeConfig(input)

    @JvmStatic
    fun resolveOptions(input: Any?): Map<String, Any?> = Config.resolveOptions(input)

    @JvmStatic
    @JvmOverloads
    fun resolveOrder(bindings: List<OrderNode>, pin: Any? = null): List<String> =
        Order.resolveOrder(bindings, pin)

    @JvmStatic
    @JvmOverloads
    fun resolveCandidates(name: String, sources: Any? = null): List<String> =
        Resolve.resolveCandidates(name, sources)

    @JvmStatic
    fun applyEnv(input: Any?): Map<String, Any?> = Env.applyEnv(input)
}
