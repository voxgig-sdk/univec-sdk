// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Host.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The host: the lifecycle state machine (section 5), extension points
/// (section 6), and resource capture (section 8).
///
/// TWO RULES SHAPE EVERY METHOD BELOW.
///
/// Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
/// never interleaved; a transition triggered from inside a lifecycle callback
/// is `plugin_reentrant`. A hard rule, because it is the only way the semantics
/// can be identical in Go, in Ruby and in single-threaded JavaScript.
///
/// Reconciliation is EAGER (section 18's portability budget). A transition
/// settles by running the state machine to a fixed point, not by suspending on
/// a promise. NOTHING HERE IS `async`, and that is the decision swift most
/// invites you to get wrong: an async transition would make section 5.2's "one
/// at a time, in call order" a claim about a cooperative executor rather than
/// about the code.
///
/// `Host`, `Inst` and `Entry` ARE CLASSES. Everything else in this port is a
/// value, which is what swift is for; these three are the state machine, and
/// giving them value semantics would mean a callback mutating a copy nobody
/// reads back.

/// One registered instance. The INTERNAL record: a plugin sees `Inst`.
public final class Entry {
    public let ref: String
    public let def: Definition
    public var status: String
    public var pos: Int
    public let seq: Int
    public var options: Value
    public var state: Value = .map([:])
    public var order: Value
    public var unmet: [String] = []
    public var scope: [() throws -> Void] = []

    /// Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider ref
    /// this instance's activation actually chose, per requirement name.
    /// Re-ranking on every question silently re-points a live consumer at any
    /// better newcomer, and then losing the provider it was really using does
    /// not restart it.
    public var selected: [String: String] = [:]

    public var bindings: [Binding] = []
    public var exports: [String: Value] = [:]
    public var provides: [Value] = []
    public var inner: Host?
    public var barred = false

    init(
        _ ref: String, _ def: Definition, _ status: String,
        _ pos: Int, _ seq: Int, _ options: Value, _ order: Value
    ) {
        self.ref = ref
        self.def = def
        self.status = status
        self.pos = pos
        self.seq = seq
        self.options = options
        self.order = order
    }
}

/// What a definition's callbacks see. Deliberately not the internal record: a
/// plugin that could reach `status` could also write it.
public final class Inst {
    public let host: Host
    let entry: Entry
    public let ref: String
    public let name: String
    public let tag: String

    init(_ host: Host, _ entry: Entry) {
        self.host = host
        self.entry = entry
        self.ref = entry.ref
        let parsed = (try? Refs.parseRef(.str(entry.ref))) ?? .map([:])
        self.name = parsed.at("name").asString ?? entry.ref
        self.tag = parsed.at("tag").asString ?? ""
    }

    public var options: Value { return entry.options }

    public var state: Value { return entry.state }

    /// The state map is a VALUE, so a callback cannot mutate what it reads; this
    /// is the write. Every other port spells it `i.state[k] = v` because its
    /// maps are objects.
    public func statePut(_ key: String, _ value: Value) {
        entry.state = entry.state.setting(key, value)
    }

    /// Foreign resources the host did not hand out are registered explicitly
    /// (section 8.3); host calls are recorded automatically.
    ///
    /// SYMMETRIC WITH `acquire`, and it has to be: `open` counts the resources
    /// CURRENTLY HELD, so an entry that is registered and then unwound must
    /// leave the count where it found it.
    public func release(_ fn: @escaping () throws -> Void) throws {
        // Section 8.3: "`inst.release` outside `activate` is
        // `plugin_release_scope`". `intransition` is true in `define` too, and a
        // scope entry registered there is never unwound.
        guard host.phase == "activate" else {
            throw Types.fail("plugin_release_scope", "release called outside activate")
        }
        let done = Flag()
        let host = self.host
        entry.scope.append {
            guard !done.value else { return }
            done.value = true
            host.open -= 1
            try fn()
        }
        host.open += 1
    }

    /// The synthetic counter the driver owns, so "what is open" is data rather
    /// than an assertion each port words differently.
    ///
    /// Returns its own release, so a plugin can hand one back early. The scope
    /// still holds the entry and unwinding it twice is a no-op - releasing early
    /// must not make teardown wrong.
    public func acquire() throws -> () -> Void {
        // Section 8.1: resources are "acquired during `activate` - the scope's
        // actual job". Same reason as `release` above.
        guard host.phase == "activate" else {
            throw Types.fail("plugin_release_scope", "acquire called outside activate")
        }
        let done = Flag()
        let host = self.host
        let rel = {
            guard !done.value else { return }
            done.value = true
            host.open -= 1
        }
        entry.scope.append(rel)
        host.open += 1
        return rel
    }

    /// Bind into a host point. Declared in `define`; the host inserts it only
    /// after `activate` returns successfully (section 8.1), which is why a
    /// failing activate leaves no live binding behind.
    ///
    /// Section 12 has carried `plugin_bind_scope` - "binding declared outside
    /// `define`" - since before anything raised it, and it was the half nobody
    /// wrote: a binding added from `activate` went live without being part of
    /// the loaded definition, and a deactivate/activate cycle appended it again.
    public func bind(
        _ point: String, _ fn: @escaping BindingFn, _ band: Value = .null
    ) throws {
        guard host.phase == "define" else {
            throw Types.fail(
                "plugin_bind_scope", "bind called outside define: \(point)",
                ["ref": .str(ref), "point": .str(point)]
            )
        }
        guard host.hasPoint(point) else {
            throw Types.fail(
                "plugin_point_unknown", "no such point: \(point)", ["point": .str(point)]
            )
        }
        entry.bindings.append(Binding(ref, point, fn, band.asInt ?? 0))
    }

    /// Published for other plugins and for the application (section 11).
    public func export(_ key: String, _ value: Value) {
        entry.exports[key] = value
    }

    /// What this instance can do for others (section 11.1).
    public func provides(_ prov: Value) {
        entry.provides.append(prov)
    }

    /// Where this binding landed (section 6.6) - the plugin-side counterpart to
    /// a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
    /// available. Verification tells a plugin it was misplaced; a pin (section
    /// 7) stops the misplacement from being expressible at all. The two are not
    /// substitutes.
    public func position(_ point: String) throws -> Value {
        return try host.positionOf(.str(ref), point)
    }

    /// AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS
    /// THE INNER ONE'S LIFETIME. Registering the teardown in the instance scope
    /// is what makes that true rather than aspirational.
    public func nest(_ nestopts: HostOptions = HostOptions()) throws -> Host {
        guard host.intransition else {
            throw Types.fail(
                "plugin_release_scope", "nest called outside a lifecycle callback"
            )
        }
        let inner = Host(nestopts)
        // NOT counted: `open` must read the same before and after a nested host
        // is created.
        entry.scope.append { try inner.close() }
        entry.inner = inner
        return inner
    }
}

/// A mutable box for a captured boolean. A swift closure captures a `let` by
/// value and cannot mutate a `var` it captured unless it is a reference, so the
/// idempotence flag on a release handle needs one.
final class Flag {
    var value = false
}

/// Host construction options. A STRUCT rather than a `Value` map, for the same
/// reason `Definition` is one: `points` holds a `base` closure and `catalog`
/// holds a class, and neither fits in the JSON enum.
public struct HostOptions {
    public var catalog: Catalog?
    public var reserved: [String] = []
    public var points: [String: PointSpec] = [:]
    public var dependency: String = "restart"
    public var keys: Value = .null
    public var defaults: Value = .null
    public var profile: String?

    public init(
        catalog: Catalog? = nil,
        reserved: [String] = [],
        points: [String: PointSpec] = [:],
        dependency: String = "restart",
        keys: Value = .null,
        defaults: Value = .null,
        profile: String? = nil
    ) {
        self.catalog = catalog
        self.reserved = reserved
        self.points = points
        self.dependency = dependency
        self.keys = keys
        self.defaults = defaults
        self.profile = profile
    }
}

/// One declared extension point.
public struct PointSpec {
    public var kind: String
    public var mode: String
    public var base: NextFn?
    public var pin: Value
    public var exclusive: Bool
    public var dflt: Value

    public init(
        kind: String = "hook",
        mode: String = "emit",
        base: NextFn? = nil,
        pin: Value = .null,
        exclusive: Bool = false,
        dflt: Value = .null
    ) {
        self.kind = kind
        self.mode = mode
        self.base = base
        self.pin = pin
        self.exclusive = exclusive
        self.dflt = dflt
    }
}

public final class Host {

    let opts: HostOptions
    let dependency: String

    /// Set for the duration of a bulk teardown, so `held` knows this is a
    /// coordinated operation rather than an ad-hoc deactivation.
    var coordinated = false

    public let catalog: Catalog
    let reserved: [String]
    let points: [String: PointSpec]

    var inst: [String: Entry] = [:]
    var log: [String] = []

    /// Section 14: the lifecycle event record. `seq` distinguishes ONE
    /// INCARNATION of stripe$test from the next, which is the whole reason it is
    /// not `pos` (section 4 rule 4).
    var events: [Value] = []
    var seqn = 0
    public var open = 0
    public var intransition = false

    /// WHICH callback is running, not merely that one is. Section 8.1 puts
    /// resource capture in `activate` and 8.3 says `release` outside `activate`
    /// is `plugin_release_scope` - and `intransition` alone cannot tell
    /// `activate` from `define`, so it admitted an acquire in `define` whose
    /// scope `unload` would never unwind.
    public var phase: String?

    public init(_ options: HostOptions = HostOptions()) {
        self.opts = options
        self.dependency = options.dependency
        self.catalog = options.catalog ?? Catalog()
        self.reserved = options.reserved
        self.points = options.points
    }

    public func hasPoint(_ name: String) -> Bool { return points[name] != nil }

    // MARK: - observation

    /// Introspection NEVER advances the state (section 5.2). A status page must
    /// not be a way to accidentally import twenty packages.
    public func list() -> Value {
        var out: [String: Value] = [:]
        for (ref, e) in inst { out[ref] = .str(e.status) }
        return .map(out)
    }

    /// `canonRef` and NOT `canon`: a lookup with a malformed ref is
    /// `plugin_bad_name`, not a miss. Swallowing the parse here is what let
    /// `declare/lookup#malformed` pass while the port answered "no such
    /// instance" to a ref that was never well formed in the first place.
    public func instance(_ ref: Value) throws -> Entry? {
        return inst[try Refs.canonRef(ref)]
    }

    public func trace() -> Value { return .list(events) }

    public func observable(_ result: Value = .null) -> Value {
        return .map([
            "status": list(),
            "open": .num(Double(open)),
            "log": .list(log.map { .str($0) }),
            "result": result,
        ])
    }

    func refs() -> [String] { return inst.keys.sorted() }

    // MARK: - the state machine

    func guardTransition() throws {
        guard intransition else { return }
        throw Types.fail(
            "plugin_reentrant", "transition attempted from inside a lifecycle callback"
        )
    }

    func need(_ ref: Value) throws -> Entry {
        let rf = try Refs.canonRef(ref)
        guard let entry = inst[rf] else {
            throw Types.fail(
                "plugin_not_loaded", "no such instance: \(rf)", ["ref": .str(rf)]
            )
        }
        return entry
    }

    func checkReserved(_ ref: String) throws {
        guard reserved.contains(Refs.refName(.str(ref))) else { return }
        throw Types.fail(
            "plugin_ref_reserved", "ref is reserved by the host: \(ref)",
            ["ref": .str(ref)]
        )
    }

    func run(_ entry: Entry, _ callback: String, _ at: String) throws {
        let fn = entry.def.callback(callback)
        log.append("\(entry.ref):\(at)")
        events.append(.map([
            "ref": .str(entry.ref),
            "event": .str(at),
            "seq": .num(Double(entry.seq)),
            "status": .str(entry.status),
        ]))
        guard let f = fn else { return }

        intransition = true
        phase = at
        defer {
            intransition = false
            phase = nil
        }
        do {
            try f(Inst(self, entry))
        } catch {
            // Section 12: `plugin_define_failed` and its three siblings are "a
            // callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A
            // CODE KEEPS IT - the code is the error's identity, and a plugin
            // raising `store_unreachable` must not have it rewritten. Only a
            // code-less error is wrapped.
            if Types.codeOf(error) != "" { throw error }
            throw Types.fail(
                "plugin_\(at)_failed",
                "\(entry.ref) raised in \(at): \(Types.messageOf(error))",
                ["ref": .str(entry.ref), "cause": .str(Types.messageOf(error))]
            )
        }
    }

    /// AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare("stripe", tag: "?")`
    /// assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the assigned
    /// pair. Without `"?"`, a collision is an error.
    func autotag(_ name: String) throws -> String {
        var n = 1
        while true {
            let cand = try Refs.formatRef(.str(name), .str(String(n)))
            if inst[cand] == nil { return cand }
            n += 1
        }
    }

    @discardableResult
    public func declare(_ ref: Value, _ spec: Value = .map([:])) throws -> Entry {
        var target = ref
        if spec.at("tag").asString == "?" {
            target = .str(try autotag(Refs.refName(.str(Refs.canon(ref)))))
        }
        let rf = try Refs.canonRef(target)
        if !spec.at("hostowned").truthy { try checkReserved(rf) }

        let defname = spec.at("definition").asString ?? Refs.refName(.str(rf))
        guard let definition = catalog.get(defname) else {
            throw Types.fail(
                "plugin_unknown_definition", "not in catalog: \(defname)",
                ["name": .str(defname)]
            )
        }

        if let existing = inst[rf] {
            // Section 4 rule 1: a pair addresses at most one instance.
            // Re-declaring the SAME definition is the idempotent case; a
            // different one is a duplicate, not a silent overwrite (seneca) and
            // not an impossibility (sdkgen).
            guard existing.def.name == definition.name else {
                throw Types.fail(
                    "plugin_ref_duplicate", "instance already declared: \(rf)",
                    ["ref": .str(rf)]
                )
            }
            return existing
        }

        let entry = Entry(
            rf, definition, "declared",
            spec.at("pos").asInt ?? inst.count, seqn,
            // PRESENT AND NOT NULL, not merely present. The driver builds its
            // spec with all four keys and a null for each absent one, exactly as
            // every other port's does, so `has` would read an omitted `options`
            // as an authored empty.
            spec.at("options").isNull ? .map([:]) : spec.at("options"),
            spec.at("order")
        )
        seqn += 1
        inst[rf] = entry
        return entry
    }

    /// Section 9.1: a host that reserves a name MUST still be able to declare
    /// the instance it reserved - "The host declares those instances itself,
    /// after the user merge, and always wins."
    ///
    /// THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
    /// language here can tell the embedding host from a plugin holding the same
    /// host object. What reservation protects is CONFIGURATION - documents,
    /// overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
    /// declare/load/options - and all of that still checks.
    @discardableResult
    public func hostdeclare(_ ref: Value, _ spec: Value = .map([:])) throws -> Entry {
        try guardTransition()
        return try declare(ref, spec.setting("hostowned", .bool(true)))
    }

    @discardableResult
    public func load(_ ref: Value, _ spec: Value = .map([:])) throws -> Entry {
        try guardTransition()
        let entry = try declare(ref, spec)
        if entry.status != "declared" { return entry } // idempotent trivially

        if !spec.at("options").isNull { entry.options = spec.at("options") }
        do {
            try run(entry, "define", "define")
        } catch {
            entry.status = "failed"
            throw error
        }
        entry.status = "loaded"

        // AT LOAD, and before anything runs: a cycle through restart-causing
        // requirements does not settle, and the only safe time to report a
        // non-terminating reconcile is before it starts (section 11.3).
        // `provides` is populated by `define`, which has just run, so this is the
        // first moment the graph is complete.
        do {
            try Depend.checkCycle(graphNodes())
        } catch {
            entry.status = "failed"
            throw error
        }
        return entry
    }

    /// The requirement graph as plain data, for the pure detector.
    func graphNodes() -> [GraphNode] {
        return refs().map { rf in
            GraphNode(
                rf,
                inst[rf]!.provides.map { $0.at("name").asString ?? "" },
                Depend.requirements(inst[rf]!.options)
            )
        }
    }

    @discardableResult
    public func activate(_ ref: Value) throws -> Entry {
        try guardTransition()
        let entry = try need(ref)
        if entry.status == "live" { return entry } // no-op returning success

        if entry.status == "failed" {
            throw Types.fail(
                "plugin_bad_state", "instance has failed: \(entry.ref)",
                ["ref": .str(entry.ref)]
            )
        }
        // Section 9.6: `active: false` bars the instance from running, and the
        // bar is on the INSTANCE rather than on the apply that set it. `ready`
        // reaches this through `activate`, so one guard covers both verbs the
        // design names.
        if entry.barred {
            throw Types.fail(
                "plugin_inactive", "instance is barred by active: false: \(entry.ref)",
                ["ref": .str(entry.ref)]
            )
        }
        if entry.status == "declared" { try load(.str(entry.ref)) }

        // A declared requirement that is not live means `pending`: activation is
        // a STANDING REQUEST, not a one-shot event.
        let unmet = unmetOf(entry)
        if !unmet.isEmpty {
            entry.unmet = unmet
            entry.status = "pending"
            return entry
        }

        do {
            try run(entry, "activate", "activate")
        } catch {
            // Unwind whatever the partial activation captured, in reverse.
            _ = unwind(entry)
            entry.status = "failed"
            throw error
        }
        // Section 11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
        // later question - the cascade, `hold`, `unmet` - reads it back rather
        // than re-ranking, which is what "always-reluctant" means.
        for req in Depend.requirements(entry.options) { _ = chosen(entry, req, true) }
        entry.status = "live"
        try reconcile()
        return entry
    }

    @discardableResult
    public func deactivate(_ ref: Value) throws -> Entry {
        try guardTransition()
        let entry = try need(ref)
        if entry.status == "loaded" || entry.status == "declared" { return entry }

        // Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
        if entry.status == "failed" {
            throw Types.fail(
                "plugin_bad_state", "instance has failed: \(entry.ref)",
                ["ref": .str(entry.ref)]
            )
        }

        if entry.status == "pending" {
            // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2). It
            // never reached activate, so it holds no scope and no live bindings;
            // running the definition's deactivate there would be teardown
            // without matching setup, which plugins are not written to survive
            // and which could fail an instance that had done nothing wrong. It
            // cannot fail.
            entry.status = "loaded"
            entry.unmet = []
            return entry
        }

        try held(entry)
        try cascade(entry, [])
        try teardown(entry)
        entry.status = "loaded"
        try reconcile()
        return entry
    }

    /// The live half of leaving `live`: the callback, then the scope.
    func teardown(_ entry: Entry) throws {
        do {
            try run(entry, "deactivate", "deactivate")
        } catch {
            _ = unwind(entry)
            entry.status = "failed"
            throw error
        }
        try releaseCheck(entry, unwind(entry))
    }

    public func unload(_ ref: Value) throws {
        try guardTransition()
        let entry = try need(ref)
        if entry.status == "live" || entry.status == "pending" {
            // Section 5.2: ANY failure during a transition lands the instance in
            // `failed`, with the scope STILL FULLY UNWOUND - and the instance
            // STAYS REGISTERED, because `failed` is a state an operator has to be
            // able to see.
            if entry.status == "live" {
                try held(entry)
                try cascade(entry, [])
                try teardown(entry)
            }
            entry.status = "loaded"
        }
        if entry.status == "loaded" || entry.status == "failed" {
            defer { inst.removeValue(forKey: entry.ref) }
            try run(entry, "close", "close")
            return
        }
        inst.removeValue(forKey: entry.ref)
    }

    /// Runs the whole forward path in one call (section 5.1).
    @discardableResult
    public func ready(_ ref: Value) throws -> Entry {
        try guardTransition()
        let rf = try Refs.canonRef(ref)
        if inst[rf] == nil { try declare(.str(rf)) }
        if inst[rf]!.status == "declared" { try load(.str(rf)) }
        return try activate(.str(rf))
    }

    /// Bindings go live only when activation succeeds (section 8.1), so the
    /// teardown is the exact inverse: reverse order, always.
    ///
    /// Returns the errors the scope raised. Section 8.3: "A failing release does
    /// not stop the rest. Every entry runs, in reverse order, whatever any of
    /// them does; the errors are collected and raised as one
    /// `plugin_release_failed`."
    ///
    /// A selection belongs to ONE activation (section 11.4). Leaving `live` by
    /// any door drops it, so the next activation ranks afresh - keeping it would
    /// make a consumer prefer a provider it never actually ran against.
    func unwind(_ entry: Entry) -> [Error] {
        entry.selected = [:]
        var errors: [Error] = []
        for fn in entry.scope.reversed() {
            do { try fn() } catch { errors.append(error) }
        }
        entry.scope = []
        return errors
    }

    /// Section 8.3: "A failed release ends the instance in `failed`, exactly as
    /// a failed callback does (5.2) - a release that raised may have leaked, and
    /// an instance that may be holding resources it cannot account for must not
    /// be reactivated."
    func releaseCheck(_ entry: Entry, _ errors: [Error]) throws {
        if errors.isEmpty { return }
        entry.status = "failed"
        let causes = errors.map { Types.messageOf($0) }
        throw Types.fail(
            "plugin_release_failed",
            "release failed for \(entry.ref): " + causes.joined(separator: "; "),
            ["ref": .str(entry.ref), "cause": .list(causes.map { .str($0) })]
        )
    }

    /// A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
    /// string is shorthand for `{name}`. A ref satisfies too, because a host that
    /// genuinely needs a specific instance should not have to invent a
    /// capability for it.
    func unmetOf(_ entry: Entry) -> [String] {
        return Depend.requirements(entry.options)
            .filter { Depend.gatesActivation($0) }
            .filter { providersOf($0).isEmpty }
            .map { $0.at("name").asString ?? "" }
    }

    /// Section 11.4's always-reluctant selection, and the ONE place a provider is
    /// picked for a live instance. If this instance already selected a provider
    /// for `req` and that provider is STILL a candidate, it keeps it - a
    /// better-ranked newcomer does not take it.
    ///
    /// `remember` is false for the questions asked ABOUT an instance rather than
    /// BY it: introspection must not create a binding.
    func chosen(_ entry: Entry, _ req: Value, _ remember: Bool) -> String? {
        let cands = providersOf(req)
        if cands.isEmpty { return nil }
        let name = req.at("name").asString ?? ""
        if let held = entry.selected[name],
           cands.contains(where: { $0.at("ref").asString == held }) {
            return held
        }
        let pick = cands[0].at("ref").asString ?? ""
        if remember { entry.selected[name] = pick }
        return pick
    }

    /// The instances currently SELECTED for this one's restart-causing
    /// requirements. A BINDING IS TO AN INSTANCE, not to a capability (section
    /// 11.1): the selected one going away restarts a `static` consumer even
    /// though a survivor is available.
    func boundProviders(_ entry: Entry) -> [String] {
        var out: [String] = []
        for req in Depend.requirements(entry.options) where Depend.restartsOnLoss(req) {
            if let ref = chosen(entry, req, false), !out.contains(ref) { out.append(ref) }
        }
        return out
    }

    /// Live instances whose selected provider is `ref` and which would be
    /// restarted by losing it.
    func consumersOf(_ ref: String) -> [String] {
        return refs().filter {
            $0 != ref && inst[$0]!.status == "live"
                && boundProviders(inst[$0]!).contains(ref)
        }
    }

    /// Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
    /// reading it off `consumersOf` answered the cascade's.
    ///
    /// The cascade wants the edges that RESTART - mandatory-static and
    /// optional-static - because a restart is what it performs. `hold` says
    /// "deactivating a REQUIRED instance is `plugin_dependency_held`", and
    /// required is cardinality: `gatesActivation`, not `restartsOnLoss`. The two
    /// sets differ in both directions and each difference was a real bug.
    ///
    /// A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let a
    /// provider go that a live consumer could not do without - `dynamic` promises
    /// survival of a SWAP, and under `hold` there is no swap, so the consumer
    /// falls back to `pending`.
    ///
    /// An OPTIONAL-STATIC consumer was included, so `hold` refused a deactivation
    /// on behalf of an instance that had said in writing it does not need the
    /// thing.
    func holdersOf(_ ref: String) -> [String] {
        return refs().filter { rf in
            let c = inst[rf]!
            if rf == ref || c.status != "live" { return false }
            return Depend.requirements(c.options).contains {
                Depend.gatesActivation($0) && chosen(c, $0, false) == ref
            }
        }
    }

    func providersOf(_ req: Value) -> [Value] {
        var cands: [Value] = []
        let name = req.at("name")
        let want = Refs.canon(name)
        for ref in refs() {
            let target = inst[ref]!
            if target.status != "live" { continue }
            // A ref satisfies directly.
            if ref == want {
                cands.append(.map([
                    "ref": .str(ref),
                    "pos": .num(Double(target.pos)),
                    "provides": .map(["name": name]),
                ]))
                continue
            }
            for prov in target.provides where prov.at("name") == name {
                cands.append(.map([
                    "ref": .str(ref),
                    "pos": .num(Double(target.pos)),
                    "provides": prov,
                ]))
            }
        }
        return Capability.resolveCapability(req, .list(cands))
    }

    /// CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
    ///
    /// The cascade is part of the provider's own deactivation and runs BEFORE
    /// the provider's `deactivate` callback and scope unwind, so a consumer's
    /// teardown can still call the thing it depends on - flushing a buffer to
    /// the store it is about to lose is exactly what a `deactivate` callback is
    /// for, and a cascade that fired after the provider was already gone would
    /// make that impossible.
    func cascade(_ provider: Entry, _ seenIn: Set<String>) throws {
        var seen = seenIn
        if seen.contains(provider.ref) { return }
        seen.insert(provider.ref)

        for rf in consumersOf(provider.ref) {
            let consumer = inst[rf]!
            if consumer.status != "live" { continue }
            try cascade(consumer, seen) // deepest-first
            demote(consumer)
        }
    }

    /// Leaving `live` for `pending` - or for `failed`, because section 5.2 says
    /// ANY failure during a transition lands the instance there. Marking it
    /// `pending` handed it straight back to `reconcile`, which would activate it
    /// again the moment the provider returned.
    func demote(_ entry: Entry) {
        var bad = false
        do { try run(entry, "deactivate", "deactivate") } catch { bad = true }
        let errors = unwind(entry)
        if bad || !errors.isEmpty {
            entry.status = "failed"
            return
        }
        entry.status = "pending"
        entry.unmet = unmetOf(entry)
    }

    /// The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
    /// TEARDOWN. In a bulk operation that is removing the holders too - `close`,
    /// or an `apply` plan whose own steps deactivate them - it is suspended for
    /// exactly those holders, and the teardown still runs consumers before
    /// providers.
    func held(_ entry: Entry) throws {
        if dependency != "hold" || coordinated { return }
        let holders = holdersOf(entry.ref)
        if holders.isEmpty { return }
        throw Types.fail(
            "plugin_dependency_held",
            "instance is required by live consumers: \(entry.ref)",
            ["ref": .str(entry.ref), "holders": .list(holders.map { .str($0) })]
        )
    }

    /// EAGER reconciliation: run to a fixed point rather than scheduling.
    ///
    /// Two directions, and both are the reason `pending` exists. Activation is a
    /// STANDING REQUEST, not a one-shot event.
    func reconcile() throws {
        var moved = true
        var rounds = 0
        while moved {
            moved = false
            rounds += 1
            if rounds > 1000 { break }

            // Losses first, so a cascade settles in one pass rather than
            // alternating with re-activations.
            for rf in refs() {
                guard let entry = inst[rf], entry.status == "live" else { continue }
                // POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
                // `dynamic` requirement whose provider is gone leaves the
                // consumer LIVE and notified.
                let lost = Depend.requirements(entry.options)
                    .filter { Depend.gatesActivation($0) }
                    .filter { providersOf($0).isEmpty }
                if lost.isEmpty { continue }
                if !lost.contains(where: { Depend.restartsOnLoss($0) }) { continue }
                demote(entry)
                moved = true
            }

            for rf in refs() {
                guard let entry = inst[rf], entry.status == "pending" else { continue }
                if !unmetOf(entry).isEmpty { continue }
                do {
                    try run(entry, "activate", "activate")
                    entry.status = "live"
                    entry.unmet = []
                } catch {
                    _ = unwind(entry)
                    entry.status = "failed"
                }
                moved = true
            }
        }
    }

    // MARK: - ordering

    public func order(_ point: String? = nil) throws -> [String] {
        // Sorted by declaration SEQUENCE, which is what makes the section 7
        // sort's fall-through deterministic in a language whose maps have no
        // order at all. Section 7 breaks ties by `pos`; two instances CAN share
        // one - `declare` defaults `pos` to the registry size, so an unload
        // followed by a fresh declare reuses a surviving instance's - and past
        // that this was falling through to map order. `seq` is that order, made
        // explicit.
        let bindings = refs()
            .filter { inst[$0]!.status == "live" }
            .sorted { inst[$0]!.seq < inst[$1]!.seq }
            .map { OrderNode($0, inst[$0]!.pos, inst[$0]!.order) }
        let pin = point.flatMap { points[$0]?.pin } ?? .null
        return try Order.resolveOrder(bindings, pin)
    }

    // MARK: - points

    /// Live bindings on a point, in resolved order. Recomputed on any change to
    /// the live set (section 7) rather than cached at startup - the bug a host
    /// discovers only when something deactivates in production.
    func bound(_ point: String) throws -> [Binding] {
        var out: [Binding] = []
        for ref in try order(point) {
            let entry = inst[ref]!
            // The band is the INSTANCE's ordering block (section 7), stamped by
            // the host. A plugin passing its own would be ranking itself above
            // the order its document declared.
            let band = entry.order.at("band").asInt ?? 0
            for b in entry.bindings where b.point == point {
                out.append(Binding(b.ref, b.point, b.fn, band))
            }
        }
        return out
    }

    func pointSpec(_ point: String, _ want: String) throws -> PointSpec {
        guard let spec = points[point] else {
            throw Types.fail(
                "plugin_point_unknown", "no such point: \(point)", ["point": .str(point)]
            )
        }
        guard spec.kind == want else {
            throw Types.fail(
                "plugin_point_kind", "point is not a \(want): \(point)",
                ["point": .str(point), "kind": .str(spec.kind)]
            )
        }
        return spec
    }

    public func emit(_ point: String, _ arg: Value = .null) throws -> Value {
        let spec = try pointSpec(point, "hook")
        return try Point.pointEmit(bound(point), spec.mode, arg)
    }

    public func call(_ point: String, _ arg: Value = .null) throws -> Value {
        let spec = try pointSpec(point, "chain")
        let base = spec.base ?? { a in a }
        return try Point.compose(bound(point), base)(arg)
    }

    public func provider(_ point: String, _ arg: Value = .null) throws -> Value {
        let spec = try pointSpec(point, "provider")
        let pick = try Point.pointProvider(bound(point), .map([
            "exclusive": .bool(spec.exclusive),
        ]))
        guard let winner = pick.winner else { return spec.dflt }
        return try winner.fn(nil, arg)
    }

    /// The losers are VISIBLE rather than silently ignored (section 6.3).
    public func shadowed(_ point: String) throws -> [String] {
        guard let spec = points[point] else { return [] }
        return try Point.pointProvider(bound(point), .map([
            "exclusive": .bool(spec.exclusive),
        ])).shadowed
    }

    public func exports(_ spec: String) throws -> Value {
        var all: [Export.Exported] = []
        for ref in refs() {
            let entry = inst[ref]!
            // Exports of a `loaded` (not live) instance are VISIBLE (11).
            if entry.status == "declared" || entry.status == "failed" { continue }
            for k in entry.exports.keys.sorted() {
                all.append(Export.Exported(ref, k, entry.exports[k]!))
            }
        }
        return try Export.resolveExport(spec, all)
    }

    /// The live providers of a capability, best-first (section 11.1).
    public func capability(_ name: String) -> [String] {
        var cands: [Value] = []
        for ref in refs() {
            let entry = inst[ref]!
            if entry.status != "live" { continue }
            for prov in entry.provides where prov.at("name").asString == name {
                cands.append(.map([
                    "ref": .str(ref),
                    "pos": .num(Double(entry.pos)),
                    "provides": prov,
                ]))
            }
        }
        return Capability.resolveCapability(.map(["name": .str(name)]), .list(cands))
            .map { $0.at("ref").asString ?? "" }
    }

    // MARK: - documents

    func shapeOf(_ ref: String) -> Value {
        return catalog.get(Refs.refName(.str(ref)))?.shape ?? .null
    }

    /// Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
    /// changed, and move activation state to match", with the stated ordering -
    /// "deactivations and unloads first (reverse load order), then loads, then
    /// activations in load order".
    ///
    /// FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
    /// document once, which never looked at instances the new document had
    /// DROPPED - so an integration removed from a config reload stayed live with
    /// its bindings and resources.
    public func apply(_ doc: Value, _ profile: String? = nil) throws {
        try guardTransition()
        let useProfile = profile ?? opts.profile
        let norm = try Config.normalizeConfig(.map([
            "doc": doc,
            "profile": useProfile.map { Value.str($0) } ?? .null,
            "keys": opts.keys,
            "reserved": .list(reserved.map { .str($0) }),
        ]))

        let want = norm.at("order").items.map { $0.asString ?? "" }
        var optionsof: [String: Value] = [:]
        for ref in want {
            optionsof[ref] = try Config.resolveOptions(.map([
                "ref": .str(ref),
                "doc": doc,
                "profile": useProfile.map { Value.str($0) } ?? .null,
                "shape": shapeOf(ref),
                "hostdefaults": opts.defaults.at(Refs.refName(.str(ref))),
            ]))
        }

        // Should this ref be LIVE after the apply? False for a ref the document
        // declares lazy or inactive AND for one it does not name at all - which
        // is what makes "unload what is gone" and "unload what was toggled off"
        // one rule rather than two.
        let wantlive = { (ref: String) -> Bool in
            guard let ent = norm.at("instance").get(ref) else { return false }
            return ent.at("active").truthy && ent.at("start").asString == "eager"
        }

        // --- phase 1: deactivations and unloads, REVERSE load order ---------
        let drop = refs().filter { inst[$0]!.status != "declared" && !wantlive($0) }
        // Highest `pos` first, ref-descending for a tie, so a consumer declared
        // after its provider goes down first.
        let ordered = drop.sorted { a, b in
            let pa = inst[a]!.pos, pb = inst[b]!.pos
            return pa == pb ? a > b : pa > pb
        }
        for ref in ordered { try unload(.str(ref)) }

        // --- phase 2: declare and patch EVERYTHING, in load order -----------
        for ref in want {
            let ent = norm.at("instance").at(ref)
            try declare(.str(ref), .map([
                "options": optionsof[ref]!,
                "order": ent.at("order"),
                "pos": ent.at("pos"),
            ]))
            let entry = inst[ref]!
            // The bar is REASSERTED ON EVERY APPLY, in both directions - a
            // document that turns the instance back on clears it, which is the
            // whole point of a config switch.
            entry.barred = !ent.at("active").truthy
            entry.options = optionsof[ref]!
            entry.order = ent.at("order")
            entry.pos = ent.at("pos").asInt ?? 0
        }

        // --- phase 3: loads, in load order ----------------------------------
        // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
        // twenty map entries and no executed code" (9.6).
        for ref in want where wantlive(ref) { try load(.str(ref)) }

        // --- phase 4: activations, in load order ----------------------------
        for ref in want where wantlive(ref) { try activate(.str(ref)) }
    }

    public func options(_ ref: Value, _ patch: Value) throws {
        try guardTransition()
        let entry = try need(ref)
        let previous = entry.options
        var merged = previous.asMap
        for k in patch.keys { merged[k] = patch.at(k) }

        let resolved = try Config.resolveOptions(.map([
            "ref": .str(entry.ref),
            "shape": shapeOf(entry.ref),
            "doc": .map([:]),
            "patch": .map(merged),
        ]))
        entry.options = resolved
        if entry.status != "live" { return }

        if let reconfigure = entry.def.reconfigure {
            intransition = true
            defer { intransition = false }
            try reconfigure(Inst(self, entry), resolved, previous)
        } else {
            // Always correct and sometimes expensive; `reconfigure` exists to
            // make the common case cheap (section 9.4).
            try deactivate(.str(entry.ref))
            try activate(.str(entry.ref))
        }
    }

    public func close() throws {
        // A bulk teardown removing the holders too, so `hold` is suspended for
        // exactly those holders (section 11.3) - while the consumers-first
        // cascade still runs, which is the half that matters.
        coordinated = true
        defer { coordinated = false }
        for rf in refs().reversed() { try unload(.str(rf)) }
    }

    /// The same record section 6.6 gives a plugin about itself, reachable from
    /// outside for the corpus.
    public func positionOf(_ ref: Value, _ point: String) throws -> Value {
        guard let entry = inst[Refs.canon(ref)] else {
            throw Types.fail(
                "plugin_not_loaded", "no such instance: \(Refs.show(ref))", ["ref": ref]
            )
        }
        let ranked = try order(point)
        let index = ranked.firstIndex(of: entry.ref) ?? -1
        return .map([
            "index": .num(Double(index)),
            "count": .num(Double(ranked.count)),
            // Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
            // OUTERMOST, so these are not index 0 and index count-1 the other way
            // round.
            "outermost": .bool(index == 0),
            "innermost": .bool(index == ranked.count - 1),
        ])
    }

    public func define(_ definition: Definition) throws { try catalog.add(definition) }
}

public func makeHost(_ options: HostOptions = HostOptions()) -> Host {
    return Host(options)
}
