// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Depend.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Dependency cardinality, policy, and the restart graph (section 11.3).
///
/// TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT, because
/// only it knows what it can cope with:
///
///                | static (default)          | dynamic
///   -------------|---------------------------|--------------------------
///   mandatory    | unmet -> pending;         | unmet -> pending;
///   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
///                |          recursively      |          notified
///   -------------|---------------------------|--------------------------
///   optional:true| never gates activation;   | never gates activation;
///                | a change deactivates and  | a change is a
///                | reactivates               | notification, nothing else
///
/// `dynamic` means the plugin has said, IN WRITING, that it can survive its
/// provider being swapped underneath it. It is not the default because most
/// plugins cannot, and the cost of wrongly assuming they can is a live instance
/// holding a dead reference.
///
/// The rebinding-preference axis is deliberately omitted. OSGi has reluctant vs
/// greedy and it is a knob every author must understand to read anyone else's
/// component; we take always-reluctant. Three axes were more than the model can
/// carry across twenty ports.

/// One node of the requirement graph. An internal shape, never a corpus value.
public struct GraphNode {
    public let ref: String
    public let provides: [String]
    public let requires: [Value]

    public init(_ ref: String, _ provides: [String], _ requires: [Value]) {
        self.ref = ref
        self.provides = provides
        self.requires = requires
    }
}

public enum Depend {

    /// A bare string is shorthand for `{name}`.
    public static func normRequire(_ raw: Value) -> Value {
        if let s = raw.asString { return .map(["name": .str(s)]) }
        if raw.isMap { return raw }
        return .map([:])
    }

    /// The requirements a definition declared, normalized.
    ///
    /// BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
    ///
    /// The instance-level `policy` and `optional` list are how a DOCUMENT states
    /// the axis without editing the definition, and they apply to every
    /// requirement. The per-requirement form is the one section 11.1's object
    /// syntax exists for, and it is strictly more expressive: an instance that
    /// is `static` on its store and `dynamic` on its metrics cannot be written
    /// at all at the instance level.
    ///
    /// `optional` unions rather than overriding - both spellings are statements
    /// that this requirement need not gate activation, and there is no reading
    /// under which one of them means "actually, mandatory".
    public static func requirements(_ options: Value) -> [Value] {
        let raw = options.at("requires").items
        let marked = options.at("optional")
        let fallback = options.get("policy")

        return raw.map { item -> Value in
            var req = normRequire(item)
            let listed = marked.isList && marked.items.contains(req.at("name"))
            if req.at("optional").truthy || listed {
                req = req.setting("optional", .bool(true))
            }
            if !req.has("policy"), let f = fallback, !f.isNull {
                req = req.setting("policy", f)
            }
            return req
        }
    }

    /// Does losing this requirement's SELECTED provider restart the consumer?
    /// The mandatory ones under `static`, and the `static` optional ones - both
    /// make a capability change deactivate and reactivate. `dynamic` never
    /// restarts.
    public static func restartsOnLoss(_ req: Value) -> Bool {
        let policy = req.get("policy")
        return (policy?.isNull ?? true) ? true : policy!.asString != "dynamic"
    }

    /// Does an unmet requirement keep the consumer out of `live`?
    ///
    /// Cardinality alone decides this, NOT policy. `dynamic` is a statement
    /// about surviving a SWAP, not about starting without the thing at all - a
    /// mandatory-dynamic consumer still waits in `pending` for its first
    /// provider.
    public static func gatesActivation(_ req: Value) -> Bool {
        return req.at("optional") != .bool(true)
    }

    /// Edges that can cause a restart, which is exactly the set a cycle must be
    /// detected over (section 11.3).
    ///
    /// ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
    /// exclusion was for: two plugins that optionally and dynamically consume
    /// each other's capabilities both activate happily, neither gates on the
    /// other, and each is merely notified when the other appears. Nothing
    /// restarts, so nothing oscillates. An earlier draft of section 11.3
    /// excluded EVERY optional edge and thereby admitted the non-terminating
    /// case it was trying to permit.
    public static func restartCausing(_ req: Value) -> Bool {
        return gatesActivation(req) || restartsOnLoss(req)
    }

    /// A cycle through restart-causing requirements is
    /// `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
    /// because the failure it describes is a non-terminating reconcile and the
    /// only safe time to report that is before it starts.
    ///
    /// The graph is over capabilities, not refs: an edge runs from a consumer to
    /// EVERY node that provides what it needs, because any of them could be the
    /// one selected and a cycle through any is a cycle. A node also satisfies
    /// its own name as a ref (section 11.1), which is why the ref is a provider
    /// of itself here.
    public static func dependencyCycle(_ nodes: [GraphNode]) -> [String]? {
        // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
        // matched differently - a capability by its exact name, a ref
        // through the canonical spelling (section 4 rule 5) - and one map
        // keyed by both can only do one of them. Keyed by both and looked
        // up raw, as this was, a cycle spelled `a$`/`b$` found no
        // providers and EVADED the load-time check that exists to catch a
        // non-terminating reconcile.
        var bycap: [String: [String]] = [:]
        var isref: Set<String> = []
        for n in nodes {
            isref.insert(n.ref)
            for cap in n.provides {
                bycap[cap, default: []].append(n.ref)
            }
        }

        var edges: [String: [String]] = [:]
        for n in nodes {
            var out: [String] = []
            for req in n.requires where restartCausing(req) {
                let reqname = req.at("name").asString ?? ""
                var from = bycap[reqname] ?? []
                // A node satisfies its own name AS A REF (section 11.1),
                // canonically - exactly what `providersOf` does at
                // runtime. `canon` hands back a name no ref could have
                // unchanged, and no instance ref can equal one.
                let asref = Refs.canon(.str(reqname))
                if isref.contains(asref) && !from.contains(asref) {
                    from.append(asref)
                }
                for p in from {
                    if p != n.ref && !out.contains(p) { out.append(p) }
                }
            }
            edges[n.ref] = out.sorted()
        }

        // Iterative DFS with an explicit stack: twenty ports, and several of
        // them have no recursion budget worth relying on.
        let white = 0, grey = 1, black = 2
        var colour: [String: Int] = [:]
        for n in nodes { colour[n.ref] = white }

        for start in edges.keys.sorted() where colour[start] == white {
            var path = [start]
            var stack: [(String, Int)] = [(start, 0)]
            colour[start] = grey

            while !stack.isEmpty {
                let (node, cursor) = stack[stack.count - 1]
                let outs = edges[node]!
                if cursor >= outs.count {
                    colour[node] = black
                    stack.removeLast()
                    path.removeLast()
                    continue
                }
                let next = outs[cursor]
                stack[stack.count - 1] = (node, cursor + 1)
                if colour[next] == grey {
                    // Report the cycle itself, not the walk that found it.
                    return Array(path[path.firstIndex(of: next)!...]) + [next]
                }
                if colour[next] == black { continue }
                colour[next] = grey
                path.append(next)
                stack.append((next, 0))
            }
        }
        return nil
    }

    /// Raise on a cycle, naming it. Separate from the detector so the detector
    /// stays pure and corpus-testable.
    public static func checkCycle(_ nodes: [GraphNode]) throws {
        guard let cycle = dependencyCycle(nodes) else { return }
        throw Types.fail(
            "plugin_dependency_cycle",
            "requirements cycle: " + cycle.joined(separator: " -> "),
            ["cycle": .list(cycle.map { .str($0) })]
        )
    }
}
