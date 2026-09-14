// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Graph.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Whole-graph resolution (section 11.4) - a phase, not a discovery.
///
/// "Activate, and wait in `pending` if you must" is correct and, on its own,
/// produces a terrible experience: apply twenty instances against a registry
/// missing one thing and you get NINETEEN pending rows and no statement of what
/// is actually wrong.
///
/// `resolveGraph` is a PURE FUNCTION of the registry and the intended
/// activation set. No callbacks run, no state changes, nothing is touched. It
/// answers for the whole graph at once which instances can be live, and for
/// each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
///
/// The failure mode being designed against is a famous one: OSGi's resolver is
/// correct and its diagnostics are legendarily unusable. A resolver that says
/// "blocked" without saying WHY has moved the problem rather than solved it, so
/// `why` is part of the contract and the corpus pins its shape.
public enum Graph {

    public static func resolveGraph(_ nodes: Value) -> Value {
        var byref: [String: Value] = [:]
        for n in nodes.items { byref[n.at("ref").asString ?? ""] = n }

        var resolved: Set<String> = []

        // Fixed point: a node resolves when every mandatory requirement is met
        // by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
        // makes a provider that is itself blocked propagate, rather than each
        // node being judged against the raw registry.
        var moved = true
        while moved {
            moved = false
            for n in nodes.items {
                let ref = n.at("ref").asString ?? ""
                if resolved.contains(ref) { continue }
                if firstUnmet(n, byref, resolved) != nil { continue }
                resolved.insert(ref)
                moved = true
            }
        }

        var blocked: [String: Value] = [:]
        for n in nodes.items {
            let ref = n.at("ref").asString ?? ""
            if resolved.contains(ref) { continue }
            guard let why = firstUnmet(n, byref, resolved) else { continue }
            blocked[ref] = why
        }

        return .map([
            "resolved": .list(resolved.sorted().map { .str($0) }),
            "blocked": .list(blocked.keys.sorted().map { blocked[$0]! }),
        ])
    }

    /// The FIRST unmet requirement, with the most specific explanation
    /// available. Order matters: "no provider at all" and "a provider at the
    /// wrong version" are different problems and a reader must not have to guess
    /// which they have.
    public static func firstUnmet(
        _ node: Value, _ byref: [String: Value], _ resolved: Set<String>
    ) -> Value? {
        for req in node.at("requires").items {
            if req.at("optional").truthy { continue }
            let name = req.at("name").asString ?? ""

            let all = graphCandidates(byref, name)
            if all.isEmpty { return why(node, name, .map(["kind": .str("absent")])) }

            let ok = Capability.resolveCapability(req, .list(all))
            if !ok.isEmpty {
                // A provider exists and matches - but if none of them is itself
                // resolved, this node is blocked BEHIND it, and the chain is the
                // useful answer rather than "unmet".
                if ok.contains(where: { resolved.contains($0.at("ref").asString ?? "") }) {
                    continue
                }
                let chain = ok.map { $0.at("ref").asString ?? "" }.sorted()
                return why(node, name, .map([
                    "kind": .str("blocked"),
                    "chain": .list(chain.map { .str($0) }),
                ]))
            }

            // Providers exist and none matched. Say which test failed.
            if let range = req.get("range"), !range.isNull {
                let versions = all
                    .map { $0.at("provides").at("version") }
                    .filter { $0.isNull || !Version.satisfiesq($0, range) }
                    .map { $0.asString ?? "(none)" }
                if !versions.isEmpty {
                    return why(node, name, .map([
                        "kind": .str("version"),
                        "range": range,
                        "found": .list(versions.sorted().map { .str($0) }),
                    ]))
                }
            }

            if let match = req.get("match"), !match.isNull {
                for c in all {
                    let attrs = c.at("provides").at("attrs")
                    for k in match.keys {
                        if attrs.has(k),
                           Capability.matchValue(match.at(k), attrs.at(k)) { continue }
                        return why(node, name, .map([
                            "kind": .str("match"),
                            "failing": .str(k),
                            "want": match.at(k),
                            "found": attrs.at(k),
                        ]))
                    }
                }
            }

            return why(node, name, .map(["kind": .str("absent")]))
        }
        return nil
    }

    static func why(_ node: Value, _ name: String, _ reason: Value) -> Value {
        return .map(["ref": node.at("ref"), "unmet": .str(name), "why": reason])
    }

    public static func graphCandidates(_ byref: [String: Value], _ name: String) -> [Value] {
        var out: [Value] = []
        // A NODE SATISFIES ITS OWN REF (section 11.1), and the graph
        // learned it here. Considering only declared capabilities made
        // `resolve` answer `absent` about a provider sitting right there
        // and live - section 11.4's job is explaining the graph the
        // runtime reconciles, and it was explaining a different one.
        let asref = Refs.canon(.str(name))
        for ref in byref.keys.sorted() {
            let node = byref[ref]!
            // The ref match WINS OUTRIGHT for that node, as at runtime:
            // one candidate, not two, for a node both named `b` and
            // providing `b`.
            if ref == asref {
                out.append(.map([
                    "ref": node.at("ref"),
                    "pos": node.get("pos") ?? .num(0),
                    "provides": .map(["name": .str(name)]),
                ]))
                continue
            }
            for prov in node.at("provides").items where prov.at("name").asString == name {
                out.append(.map([
                    "ref": node.at("ref"),
                    "pos": node.get("pos") ?? .num(0),
                    "provides": prov,
                ]))
            }
        }
        return out
    }
}
