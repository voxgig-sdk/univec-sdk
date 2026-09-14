// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Graph.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.util.TreeMap

/**
 * Whole-graph resolution (section 11.4) - a phase, not a discovery.
 *
 * "Activate, and wait in `pending` if you must" is correct and, on its own,
 * produces a terrible experience: apply twenty instances against a registry
 * missing one thing and you get NINETEEN pending rows and no statement of what
 * is actually wrong.
 *
 * `resolveGraph` is a PURE FUNCTION of the registry and the intended
 * activation set. No callbacks run, no state changes, nothing is touched. It
 * answers for the whole graph at once which instances can be live, and for
 * each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
 *
 * The failure mode being designed against is a famous one: OSGi's resolver is
 * correct and its diagnostics are legendarily unusable. A resolver that says
 * "blocked" without saying WHY has moved the problem rather than solved it, so
 * `why` is part of the contract and the corpus pins its shape.
 */
object Graph {

    fun resolveGraph(nodes: Any?): Map<String, Any?> {
        val list = nodes as List<*>
        val byref = TreeMap<String, Any?>()
        for (n in list) byref[Types.get(n, "ref") as String] = n

        val resolved = HashSet<String>()

        // Fixed point: a node resolves when every mandatory requirement is met
        // by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
        // makes a provider that is itself blocked propagate, rather than each
        // node being judged against the raw registry.
        var moved = true
        while (moved) {
            moved = false
            for (n in list) {
                val ref = Types.get(n, "ref") as String
                if (resolved.contains(ref)) continue
                if (null != firstUnmet(n, byref, resolved)) continue
                resolved.add(ref)
                moved = true
            }
        }

        val blocked = TreeMap<String, Any?>()
        for (n in list) {
            val ref = Types.get(n, "ref") as String
            if (resolved.contains(ref)) continue
            val why = firstUnmet(n, byref, resolved) ?: continue
            blocked[ref] = why
        }

        val out = TreeMap<String, Any?>()
        out["resolved"] = resolved.sorted()
        out["blocked"] = blocked.values.toList()
        return out
    }

    /**
     * The FIRST unmet requirement, with the most specific explanation
     * available. Order matters: "no provider at all" and "a provider at the
     * wrong version" are different problems and a reader must not have to
     * guess which they have.
     */
    fun firstUnmet(node: Any?, byref: Map<String, Any?>, resolved: Set<String>): Any? {
        for (req in (Types.get(node, "requires") ?: emptyList<Any?>()) as List<*>) {
            if (Types.truthy(Types.get(req, "optional"))) continue
            val name = Types.get(req, "name") as String

            val all = graphCandidates(byref, name)
            if (all.isEmpty()) return why(node, name, reason("absent"))

            val ok = Capability.resolveCapability(req, all)
            if (ok.isNotEmpty()) {
                // A provider exists and matches - but if none of them is itself
                // resolved, this node is blocked BEHIND it, and the chain is
                // the useful answer rather than "unmet".
                if (ok.any { resolved.contains(Types.get(it, "ref")) }) continue
                val chain = ok.map { Types.get(it, "ref") as String }.sorted()
                val r = reason("blocked")
                r["chain"] = chain
                return why(node, name, r)
            }

            // Providers exist and none matched. Say which test failed.
            val range = Types.get(req, "range")
            if (null != range) {
                val versions = all
                    .map { Types.get(Types.get(it, "provides"), "version") }
                    .filter { null == it || !Version.satisfiesq(it, range) }
                    .map { (it ?: "(none)") as String }
                if (versions.isNotEmpty()) {
                    val r = reason("version")
                    r["range"] = range
                    r["found"] = versions.sorted()
                    return why(node, name, r)
                }
            }

            val match = Types.get(req, "match")
            if (null != match) {
                for (c in all) {
                    val attrs = Types.get(Types.get(c, "provides"), "attrs")
                        ?: emptyMap<String, Any?>()
                    for (k in Types.keys(match)) {
                        if (Types.has(attrs, k) &&
                            Capability.matchValue(Types.get(match, k), Types.get(attrs, k))
                        ) {
                            continue
                        }
                        val r = reason("match")
                        r["failing"] = k
                        r["want"] = Types.get(match, k)
                        r["found"] = Types.get(attrs, k)
                        return why(node, name, r)
                    }
                }
            }

            return why(node, name, reason("absent"))
        }
        return null
    }

    private fun reason(kind: String): TreeMap<String, Any?> {
        val out = TreeMap<String, Any?>()
        out["kind"] = kind
        return out
    }

    private fun why(node: Any?, name: String, reason: Any?): Map<String, Any?> {
        val out = TreeMap<String, Any?>()
        out["ref"] = Types.get(node, "ref")
        out["unmet"] = name
        out["why"] = reason
        return out
    }

    fun graphCandidates(byref: Map<String, Any?>, name: String): List<Any?> {
        val out = ArrayList<Any?>()
        // A NODE SATISFIES ITS OWN REF (section 11.1), and the graph
        // learned it here. Considering only declared capabilities made
        // `resolve` answer `absent` about a provider sitting right there
        // and live - section 11.4's job is explaining the graph the
        // runtime reconciles, and it was explaining a different one.
        val asref = Refs.canon(name)
        for (ref in Types.keys(byref)) {
            val node = byref[ref]
            // The ref match WINS OUTRIGHT for that node, as at runtime:
            // one candidate, not two, for a node both named `b` and
            // providing `b`.
            if (ref == asref) {
                val rc = TreeMap<String, Any?>()
                rc["ref"] = Types.get(node, "ref")
                rc["pos"] = Types.get(node, "pos") ?: 0.0
                val prov0 = TreeMap<String, Any?>()
                prov0["name"] = name
                rc["provides"] = prov0
                out.add(rc)
                continue
            }
            for (prov in (Types.get(node, "provides") ?: emptyList<Any?>()) as List<*>) {
                if (Types.get(prov, "name") != name) continue
                val c = TreeMap<String, Any?>()
                c["ref"] = Types.get(node, "ref")
                c["pos"] = Types.get(node, "pos") ?: 0.0
                c["provides"] = prov
                out.add(c)
            }
        }
        return out
    }
}
