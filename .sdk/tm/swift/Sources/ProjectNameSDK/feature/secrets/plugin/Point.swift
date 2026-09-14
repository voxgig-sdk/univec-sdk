// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Point.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Extension points (section 6). Three kinds, chosen because they are what the
/// two existing systems actually needed, and no more.
///
/// A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes deactivation
/// possible: sdkgen's `utility.fetcher = wrapped` is not undoable, but "this
/// instance holds slot 3 of the request chain" is undoable in O(1). OSGi named
/// it the whiteboard pattern in 2004, in a paper called *Listeners Considered
/// Harmful*, and for exactly this reason.

/// EVERY BINDING IS ARITY TWO, `(next, arg)`, hook and chain alike. `next` is
/// nil for a hook. One signature means `Point` does not have to know which kind
/// of point it is holding - and the kind is the HOST's property, not the
/// binding's. It `throws`, because a plugin's callback can fail and swift makes
/// that part of the type.
public typealias NextFn = (Value) throws -> Value
public typealias BindingFn = (NextFn?, Value) throws -> Value

/// A live binding. An internal shape, never a corpus value.
public struct Binding {
    public let ref: String
    public let point: String
    public let fn: BindingFn
    public var band: Int

    public init(_ ref: String, _ point: String, _ fn: @escaping BindingFn, _ band: Int) {
        self.ref = ref
        self.point = point
        self.fn = fn
        self.band = band
    }
}

/// The winner and the losers on a provider point.
public struct Picked {
    public let winner: Binding?
    public let shadowed: [String]
}

public enum Point {

    /// Section 6.1: "fan-out" is not one answer but four. In a language with
    /// asynchrony, "call every binding" hides a decision - start them all and
    /// wait, await each in turn, or do not wait - and a design that leaves it
    /// unsaid gets four different answers from four ports, in the concurrency
    /// behaviour of production code no corpus entry happens to cover.
    ///
    /// SWIFT IS A PORT WHERE THAT IS LOUD: `async` and a `TaskGroup` are one
    /// keyword away, and using either for `emit` would make every hook point a
    /// suspension point and every ordering assertion a race. The host stays
    /// synchronous (section 5.2) and the modes stay data.
    public static let modes = ["emit", "parallel", "serial", "bail"]

    /// Fan-out. Return values are ignored except in `bail`.
    public static func pointEmit(
        _ bindings: [Binding], _ mode: String, _ arg: Value
    ) throws -> Value {
        if mode == "bail" {
            // Stops at the first binding that RETURNS A VALUE - the "handled,
            // stop" case. A `.null` RETURN DECLINES (section 6.1): swift has one
            // way to say nothing here, and the model's rule is written to that
            // rather than to JavaScript's null/undefined pair. `!isNull`, NOT
            // truthiness - `false` is a value.
            for b in bindings {
                let v = try b.fn(nil, arg)
                if !v.isNull { return v }
            }
            return .null
        }

        var errors: [Value] = []
        for b in bindings {
            do {
                _ = try b.fn(nil, arg)
            } catch {
                // `emit` raises synchronously; the collecting modes gather.
                if mode == "emit" { throw error }
                errors.append(.str(Types.messageOf(error)))
            }
        }
        return mode == "emit" ? .null : .list(errors)
    }

    /// Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
    ///
    /// Recomputed by the host whenever the live set changes, and cached between
    /// changes. Plugins receive `next` as an argument; they never see or store
    /// the previous value of anything. A plugin that stashes `next` and calls
    /// it after deactivation is a bug the host cannot prevent, and this says so
    /// rather than pretending otherwise.
    public static func compose(
        _ bindings: [Binding], _ base: @escaping NextFn
    ) -> NextFn {
        var next = base
        for i in stride(from: bindings.count - 1, through: 0, by: -1) {
            // `fn` and `inner` are declared INSIDE the loop, so each layer
            // closes over its own pair. Swift captures the variable rather than
            // the value, and hoisting either would leave every layer calling the
            // last one.
            let fn = bindings[i].fn
            let inner = next
            next = { arg in try fn(inner, arg) }
        }
        return next
    }

    /// At most one live implementation (section 6.3). The winner is the highest
    /// band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
    /// silently ignored.
    public static func pointProvider(_ bindings: [Binding], _ spec: Value) throws -> Picked {
        if bindings.isEmpty { return Picked(winner: nil, shadowed: []) }

        if spec.at("exclusive").truthy && bindings.count > 1 {
            let refs = bindings.map { $0.ref }.sorted()
            throw Types.fail(
                "plugin_point_exclusive",
                "point is exclusive and has \(bindings.count) bindings: "
                    + refs.joined(separator: ", "),
                ["refs": .list(refs.map { .str($0) })]
            )
        }

        let ranked = Types.stableSortBy(bindings) {
            [SortKey.num(Double(-$0.band)), SortKey.text($0.ref)]
        }
        return Picked(winner: ranked[0], shadowed: ranked.dropFirst().map { $0.ref })
    }
}
