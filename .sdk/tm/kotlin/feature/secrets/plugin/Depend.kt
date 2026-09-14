// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Depend.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Dependency cardinality, policy, and the restart graph (section 11.3).
 *
 * TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT, because
 * only it knows what it can cope with:
 *
 *                | static (default)          | dynamic
 *   -------------|---------------------------|--------------------------
 *   mandatory    | unmet -> pending;         | unmet -> pending;
 *   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
 *                |          recursively      |          notified
 *   -------------|---------------------------|--------------------------
 *   optional:true| never gates activation;   | never gates activation;
 *                | a change deactivates and  | a change is a
 *                | reactivates               | notification, nothing else
 *
 * `dynamic` means the plugin has said, IN WRITING, that it can survive its
 * provider being swapped underneath it. It is not the default because most
 * plugins cannot, and the cost of wrongly assuming they can is a live instance
 * holding a dead reference.
 *
 * The rebinding-preference axis is deliberately omitted. OSGi has reluctant vs
 * greedy and it is a knob every author must understand to read anyone else's
 * component; we take always-reluctant. Three axes were more than the model can
 * carry across twenty ports.
 */

/** One node of the requirement graph. An internal shape, never a corpus value. */
data class GraphNode(
    val ref: String,
    val provides: List<String>,
    val requires: List<Map<String, Any?>>
)

object Depend {

    /** A bare string is shorthand for `{name}`. */
    fun normRequire(raw: Any?): MutableMap<String, Any?> {
        val out = java.util.TreeMap<String, Any?>()
        if (raw is String) {
            out["name"] = raw
            return out
        }
        if (raw is Map<*, *>) {
            for (k in Types.keys(raw)) out[k] = Types.get(raw, k)
        }
        return out
    }

    /**
     * The requirements a definition declared, normalized.
     *
     * BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
     *
     * The instance-level `policy` and `optional` list are how a DOCUMENT
     * states the axis without editing the definition, and they apply to every
     * requirement. The per-requirement form is the one section 11.1's object
     * syntax exists for, and it is strictly more expressive: an instance that
     * is `static` on its store and `dynamic` on its metrics cannot be written
     * at all at the instance level.
     *
     * `optional` unions rather than overriding - both spellings are statements
     * that this requirement need not gate activation, and there is no reading
     * under which one of them means "actually, mandatory".
     */
    fun requirements(options: Any?): List<Map<String, Any?>> {
        val raw = (Types.get(options, "requires") ?: emptyList<Any?>()) as List<*>
        val marked = Types.get(options, "optional")
        val fallback = Types.get(options, "policy")

        return raw.map { item ->
            val req = normRequire(item)
            if (Types.truthy(req["optional"]) ||
                (marked is List<*> && marked.contains(req["name"]))
            ) {
                req["optional"] = true
            }
            if (null == req["policy"] && null != fallback) req["policy"] = fallback
            req
        }
    }

    /**
     * Does losing this requirement's SELECTED provider restart the consumer?
     * The mandatory ones under `static`, and the `static` optional ones - both
     * make a capability change deactivate and reactivate. `dynamic` never
     * restarts.
     */
    fun restartsOnLoss(req: Any?): Boolean =
        "dynamic" != (Types.get(req, "policy") ?: "static")

    /**
     * Does an unmet requirement keep the consumer out of `live`?
     *
     * Cardinality alone decides this, NOT policy. `dynamic` is a statement
     * about surviving a SWAP, not about starting without the thing at all - a
     * mandatory-dynamic consumer still waits in `pending` for its first
     * provider.
     */
    fun gatesActivation(req: Any?): Boolean = true != Types.get(req, "optional")

    /**
     * Edges that can cause a restart, which is exactly the set a cycle must be
     * detected over (section 11.3).
     *
     * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
     * exclusion was for: two plugins that optionally and dynamically consume
     * each other's capabilities both activate happily, neither gates on the
     * other, and each is merely notified when the other appears. Nothing
     * restarts, so nothing oscillates. An earlier draft of section 11.3
     * excluded EVERY optional edge and thereby admitted the non-terminating
     * case it was trying to permit.
     */
    fun restartCausing(req: Any?): Boolean = gatesActivation(req) || restartsOnLoss(req)

    /**
     * A cycle through restart-causing requirements is
     * `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
     * because the failure it describes is a non-terminating reconcile and the
     * only safe time to report that is before it starts.
     *
     * The graph is over capabilities, not refs: an edge runs from a consumer
     * to EVERY node that provides what it needs, because any of them could be
     * the one selected and a cycle through any is a cycle. A node also
     * satisfies its own name as a ref (section 11.1), which is why the ref is
     * a provider of itself here.
     */
    fun dependencyCycle(nodes: List<GraphNode>): List<String>? {
        // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
        // matched differently - a capability by its exact name, a ref
        // through the canonical spelling (section 4 rule 5) - and one map
        // keyed by both can only do one of them. Keyed by both and looked
        // up raw, as this was, a cycle spelled `a$`/`b$` found no
        // providers and EVADED the load-time check that exists to catch a
        // non-terminating reconcile.
        val bycap = HashMap<String, MutableList<String>>()
        val isref = HashSet<String>()
        for (n in nodes) {
            isref.add(n.ref)
            for (cap in n.provides) {
                bycap.getOrPut(cap) { ArrayList() }.add(n.ref)
            }
        }

        val edges = HashMap<String, List<String>>()
        for (n in nodes) {
            val out = ArrayList<String>()
            for (req in n.requires) {
                if (!restartCausing(req)) continue
                val reqname = Types.get(req, "name")
                val from = ArrayList<String>(bycap[reqname] ?: emptyList<String>())
                // A node satisfies its own name AS A REF (section 11.1),
                // canonically - exactly what `providersOf` does at
                // runtime. `canon` hands back a name no ref could have
                // unchanged, and no instance ref can equal one.
                val asref = Refs.canon(reqname)
                if (isref.contains(asref) && !from.contains(asref)) from.add(asref)
                for (p in from) {
                    if (p != n.ref && !out.contains(p)) out.add(p)
                }
            }
            edges[n.ref] = out.sorted()
        }

        // Iterative DFS with an explicit stack: twenty ports, and several of
        // them have no recursion budget worth relying on.
        val white = 0
        val grey = 1
        val black = 2
        val colour = HashMap<String, Int>()
        for (n in nodes) colour[n.ref] = white

        for (start in edges.keys.sorted()) {
            if (white != colour[start]) continue

            val path = ArrayList<String>()
            path.add(start)
            val stack = ArrayList<IntArray>()
            val nodeAt = ArrayList<String>()
            stack.add(intArrayOf(0))
            nodeAt.add(start)
            colour[start] = grey

            while (stack.isNotEmpty()) {
                val node = nodeAt[nodeAt.size - 1]
                val cursor = stack[stack.size - 1]
                val outs = edges[node]!!
                if (cursor[0] >= outs.size) {
                    colour[node] = black
                    stack.removeAt(stack.size - 1)
                    nodeAt.removeAt(nodeAt.size - 1)
                    path.removeAt(path.size - 1)
                    continue
                }
                val next = outs[cursor[0]]
                cursor[0]++
                if (grey == colour[next]) {
                    // Report the cycle itself, not the walk that found it.
                    return path.subList(path.indexOf(next), path.size).toList() + next
                }
                if (black == colour[next]) continue
                colour[next] = grey
                path.add(next)
                stack.add(intArrayOf(0))
                nodeAt.add(next)
            }
        }
        return null
    }

    /**
     * Raise on a cycle, naming it. Separate from the detector so the detector
     * stays pure and corpus-testable.
     */
    fun checkCycle(nodes: List<GraphNode>) {
        val cycle = dependencyCycle(nodes) ?: return
        Types.fail(
            "plugin_dependency_cycle", "requirements cycle: ${cycle.joinToString(" -> ")}",
            mapOf("cycle" to cycle)
        )
    }
}
