// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Catalog.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.util.TreeMap

/**
 * The definition catalog (section 10.1).
 *
 * A definition is registered once and may back many instances. Option shapes
 * are validated AT REGISTRATION, not when a document happens to exercise a key
 * - so a malformed shape fails once, and in the same place everywhere
 * (section 9.4).
 */
class Catalog {

    private val defs = TreeMap<String, Any?>()

    fun add(definition: Any?) {
        val name = Types.get(definition, "name")
        if (definition !is Map<*, *> || !Refs.checkName(name)) {
            val shown = if (definition is Map<*, *>) name else definition
            Types.fail("plugin_definition_name", "invalid definition name: $shown")
        }
        // Validate the shape HERE. Deferring it to resolution time means a
        // malformed shape surfaces at a different moment in every host that
        // loads it, which is the divergence the stated domain exists to
        // prevent.
        val shape = Types.get(definition, "shape")
        if (null != shape) Config.checkShape(shape)
        defs[name as String] = definition
    }

    fun get(name: String): Any? = defs[name]

    fun has(name: String): Boolean = defs.containsKey(name)

    fun names(): List<String> = defs.keys.toList()
}
