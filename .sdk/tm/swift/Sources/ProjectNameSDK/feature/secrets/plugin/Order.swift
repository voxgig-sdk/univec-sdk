// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Order.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Ordering (section 7) - one rule, one place.
///
/// sdkgen grew two special cases in `makeOptions` (`test`, then `station`) and
/// the third was not far off. This sort is the whole replacement, and the tiers
/// are in this order for a reason:
///
///   1 constraints   before/after edges, by ref or by name
///   2 bands         integer, lower first, default 0
///   3 declaration   ties break by `pos`
///
/// CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
/// present. A band expresses a genuine cross-cutting layer; a constraint
/// expresses a relationship between two specific things; and a band chosen by
/// trial and error to fix an ordering bug is a bug wearing a number.

/// One node of the sort. An internal shape, never a corpus value.
public struct OrderNode {
    public let ref: String
    public let pos: Int
    public let order: Value

    public init(_ ref: String, _ pos: Int, _ order: Value) {
        self.ref = ref
        self.pos = pos
        self.order = order
    }
}

public enum Order {

    public static func orderBand(_ b: OrderNode) -> Int {
        return b.order.at("band").asInt ?? 0
    }

    /// Was a constraint stated? An absent value and an EMPTY LIST are both
    /// no-constraint - and an empty list is TRUTHY in most languages, which is
    /// exactly how this class of bug survives a reading.
    public static func orderDeclared(_ spec: Value) -> Bool {
        if spec.isNull { return false }
        if case .list(let l) = spec { return l.contains { $0 != .str("") } }
        return spec != .str("")
    }

    /// One spelling or a LIST of them. A list fans out to the UNION of what each
    /// names, so after: ['a','b'] means after BOTH, and the same instance named
    /// twice - once by name, once by ref - is one edge.
    ///
    /// Matching is by REF, or by NAME across all of that definition's instances
    /// (section 7) - which is the whole reason the two spellings exist.
    public static func orderTargets(_ spec: Value, _ nodes: [OrderNode]) -> [String] {
        let specs: [Value] = spec.isList ? spec.items : [spec]
        var hit: [String] = []
        for one in specs {
            for b in nodes {
                if hit.contains(b.ref) { continue }
                if .str(b.ref) == one || .str(Refs.refName(.str(b.ref))) == one {
                    hit.append(b.ref)
                }
            }
        }
        return hit
    }

    public static func resolveOrder(_ bindings: [OrderNode], _ pin: Value = .null) throws
        -> [String] {
        var byref: [String: OrderNode] = [:]
        for b in bindings { byref[b.ref] = b }

        // Constraints are edges. A constraint naming an ABSENT binding is
        // satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
        // must load in a host with no test plugin. That is sdkgen's __after__
        // behaviour, kept.
        var edges: [String: [String]] = [:]
        for b in bindings { edges[b.ref] = [] }

        for b in bindings {
            let block = b.order
            if orderDeclared(block.at("after")) {
                for target in orderTargets(block.at("after"), bindings) {
                    edges[target]!.append(b.ref)
                }
            }
            if orderDeclared(block.at("before")) {
                edges[b.ref]!.append(contentsOf: orderTargets(block.at("before"), bindings))
            }
        }

        var indeg: [String: Int] = [:]
        for b in bindings { indeg[b.ref] = 0 }
        for (_, tos) in edges {
            for to in tos { indeg[to]! += 1 }
        }

        // Stable topological sort. Among ready nodes, band first (lower runs
        // first), then `pos` - the position the DOCUMENT visibly states, not the
        // order instances happened to load and not the incarnation `seq`.
        var out: [String] = []
        var ready = bindings.filter { indeg[$0.ref] == 0 }

        while !ready.isEmpty {
            ready = Types.stableSortBy(ready) {
                [SortKey.num(Double(orderBand($0))), SortKey.num(Double($0.pos))]
            }
            let next = ready.removeFirst()
            out.append(next.ref)
            for to in edges[next.ref]! {
                indeg[to]! -= 1
                if indeg[to] == 0 { ready.append(byref[to]!) }
            }
        }

        if out.count != bindings.count {
            let stuck = bindings.filter { !out.contains($0.ref) }.map { $0.ref }
            throw Types.fail(
                "plugin_order_cycle",
                "before/after constraints cycle: " + stuck.joined(separator: " -> "),
                ["cycle": .list(stuck.map { .str($0) })]
            )
        }

        return try applyPin(out, edges, pin)
    }

    /// A PIN IS NOT A CONSTRAINT (section 7).
    ///
    /// Constraints and bands are negotiable by definition - they are what
    /// plugins and documents say they want, and the sort's job is to satisfy
    /// them all. A pin is the host stating a structural invariant of its own
    /// architecture, which is a different kind of claim and must not lose a tie
    /// to a document.
    ///
    /// So a pin PLACES the binding at the named end, and an ordering that would
    /// move it away is `plugin_order_pinned` - rejected, not honoured into a
    /// broken wrap.
    public static func applyPin(
        _ order: [String], _ edges: [String: [String]], _ pin: Value
    ) throws -> [String] {
        if pin.isNull { return order }
        var out = order

        // SORTED, not insertion order. A pin map is data - it can arrive from a
        // host's own construction options in any order, and two names pinned to
        // the same end are order-sensitive (`{b:'first', a:'first'}` and
        // `{a:'first', b:'first'}` give different results). A swift dictionary
        // has no order at all, so leaving it unstated made the same declaration
        // mean different things in different ports.
        for name in pin.keys {
            let want = pin.at(name).asString
            guard let idx = out.firstIndex(where: { Refs.refName(.str($0)) == name })
            else { continue }

            // `first`/`outermost` is index 0; `last`/`innermost` is the end.
            // Section 6.2 makes the first chain binding outermost, which is why
            // the vocabulary is positional and why the two spellings pair this
            // way.
            let wantFirst = want == "first" || want == "outermost"
            let ref = out.remove(at: idx)
            if wantFirst { out.insert(ref, at: 0) } else { out.append(ref) }
        }

        // Now check that the placement did not break a constraint. This is the
        // half that makes a pin a rejection rather than an override: the host
        // wins on position, but it does not get to silently discard a
        // relationship a plugin declared.
        var at: [String: Int] = [:]
        for (i, ref) in out.enumerated() { at[ref] = i }
        for from in edges.keys.sorted() {
            for to in edges[from]! {
                if at[from]! <= at[to]! { continue }
                throw Types.fail(
                    "plugin_order_pinned",
                    "a pin would move a binding an ordering constrains: "
                        + "\(from) must precede \(to)",
                    ["before": .str(from), "after": .str(to)]
                )
            }
        }
        return out
    }
}
