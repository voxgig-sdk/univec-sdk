// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Config.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The declarative document (section 9): normalization, and the ten-level
/// precedence ladder.
///
/// TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
///
/// `normalizeConfig` normalizes STRUCTURE and ENTRY KEYS. It does not merge
/// options, and cannot: section 9.4 makes merge behaviour a property of the
/// definition's option SHAPE, which normalization has never seen. A normalizer
/// that flattened the option layers would make `$MERGE: append` unimplementable
/// at load time, because the layers it must concatenate would already be
/// collapsed.
///
/// `resolveOptions` applies the ladder, and it is the only place that knows the
/// shape.
public enum Config {

    static let mergeWords = ["replace", "append"]

    struct Entries {
        var map: [String: Value] = [:]
        var order: [String] = []
    }

    /// Both document forms reduce to {ref -> entry} plus the order the form
    /// implies: array POSITION for the array form, sorted refs for the map form.
    static func entries(_ src: Value) throws -> Entries {
        var out = Entries()
        if src.isNull { return out }

        if case .list(let items) = src {
            for item in items {
                let ref = try Refs.canonRef(item.at("ref"))
                out.map[ref] = item
                out.order.append(ref)
            }
            return out
        }

        // Map-form refs arrive as KEYS, through a different path than an array
        // element's `ref` field - and must canonicalize the same way.
        for key in src.keys { out.map[try Refs.canonRef(.str(key))] = src.at(key) }
        // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
        // sort identically under all three, so only mixed input discriminates:
        // '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Swift's `<` on
        // `String` compares unicode scalars, which is exactly that for a ref.
        out.order = out.map.keys.sorted()
        return out
    }

    static func checkReserved(_ ref: String, _ reserved: Value) throws {
        guard reserved.items.contains(.str(Refs.refName(.str(ref)))) else { return }
        throw Types.fail(
            "plugin_ref_reserved", "ref is reserved by the host: \(ref)",
            ["ref": .str(ref)]
        )
    }

    /// PRESENCE decides, not truthiness and not null. A JSON `null` is a present
    /// value in JavaScript (`undefined !== null`), so it must be one here.
    static func pick(_ src: Value?, _ key: String, _ dflt: Value) -> Value {
        guard let s = src, s.has(key) else { return dflt }
        return s.at(key)
    }

    public static func normalizeConfig(_ input: Value) throws -> Value {
        let doc = input.at("doc")
        let keys = input.at("keys")
        let ikey = keys.at("instance").asString ?? "instance"
        let dkey = keys.at("default").asString ?? "default"
        let reserved = input.at("reserved")
        let profile = input.at("profile")

        // The rename is applied at TWO PLACES AND NO OTHERS: the document root,
        // and every profile.<name> overlay root (section 9.1). A rename applied
        // only at the root would leave `profile.prod.sdk` untranslated and
        // silently drop every environment override the host depends on.
        // Recursing further would be worse: option data is the definition's.
        let basedef = doc.at(dkey)
        var overlay = Value.map([:])
        if let name = profile.asString {
            let found = doc.at("profile").at(name)
            if found.isMap { overlay = found }
        }
        let overdef = overlay.at(dkey)

        let base = try entries(doc.at(ikey))
        let over = try entries(overlay.at(ikey))

        for group in [base.map.keys.sorted(), over.map.keys.sorted(),
                      basedef.keys, overdef.keys] {
            for ref in group { try checkReserved(ref, reserved) }
        }

        // A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this the
        // hard way: deriving order from a partial array silently dropped
        // config-activated features. Refs in the base but absent from the
        // overlay still load, in sorted position AFTER the listed ones. A
        // profile may also INTRODUCE a ref the base never declared. The
        // remainder keeps the BASE's own order.
        var order: [String] = []
        for ref in over.order + base.order where !order.contains(ref) { order.append(ref) }

        var instance: [String: Value] = [:]
        for (i, ref) in order.enumerated() {
            let b = base.map[ref]
            let o = over.map[ref]

            // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
            // (section 9.3). A safety rule, not a tidiness one: if the overlay
            // had its defaults filled in before merging it would carry a
            // synthesized active:true and overwrite a base's false - silently
            // re-enabling a deliberately disabled integration in production.
            let hasBlock = (o?.has("order") ?? false) || (b?.has("order") ?? false)
            let block = pick(o, "order", pick(b, "order", .null))

            // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
            let nm = Refs.refName(.str(ref))
            var layers: [Value] = []
            for src in [basedef.get(nm), b, overdef.get(nm), o] {
                if let s = src, s.has("options") { layers.append(s.at("options")) }
            }

            var ent: [String: Value] = [
                "pos": .num(Double(i)),
                "active": pick(o, "active", pick(b, "active", .bool(true))),
                "start": pick(o, "start", pick(b, "start", .str("eager"))),
                "optionlayers": .list(layers),
            ]
            if hasBlock && !block.isNull { ent["order"] = block }
            instance[ref] = .map(ent)
        }

        // `default` DECLARES NOTHING (section 9.3). It is a base for every
        // instance of that definition; it does not create one, and an entry for
        // a name with no instances is inert rather than an error - which is what
        // makes a shared library of defaults shippable.
        var defout: [String: Value] = [:]
        for k in basedef.keys { defout[k] = basedef.at(k) }
        for k in overdef.keys { defout[k] = overdef.at(k) }

        return .map([
            "instance": .map(instance),
            "order": .list(order.map { .str($0) }),
            "default": .map(defout),
        ])
    }

    /// Section 9.4: N is an integer of at least 1, and everything else is an
    /// error.
    ///
    /// `{"deep": 0}` is rejected DESPITE having an obvious reading, because
    /// "replace at this key" already has a spelling and two spellings for one
    /// behaviour is the defect class this repo exists to avoid.
    public static func checkShape(_ shape: Value) throws {
        guard shape.isMap else { return }
        for k in shape.keys {
            let v = shape.at(k)
            guard v.has("$MERGE") else { continue }
            let directive = v.at("$MERGE")

            if let word = directive.asString {
                if mergeWords.contains(word) { continue }
                throw Types.fail(
                    "plugin_shape_invalid", "invalid $MERGE directive at \(k): \(word)",
                    ["key": .str(k), "directive": directive]
                )
            }
            if directive.has("deep") {
                let n = directive.at("deep")
                // `.bool(true)` is a different enum case from `.num`, so the
                // boolean falls out for free here - unlike python, where it does
                // not.
                if let i = n.asInt, i >= 1 { continue }
                throw Types.fail(
                    "plugin_shape_invalid", "invalid $MERGE deep at \(k): \(n.json)",
                    ["key": .str(k), "directive": directive]
                )
            }
            throw Types.fail(
                "plugin_shape_invalid",
                "invalid $MERGE directive at \(k): \(directive.json)",
                ["key": .str(k), "directive": directive]
            )
        }
    }

    /// The shape's non-directive values are the level-1 defaults.
    static func defaultsOf(_ shape: Value) -> Value {
        var out: [String: Value] = [:]
        for k in shape.keys {
            let v = shape.at(k)
            if v.has("$MERGE") { continue }
            out[k] = v
        }
        return .map(out)
    }

    static func optsOf(_ src: Value, _ key: String) throws -> Value? {
        if src.isNull { return nil }
        // The array form is equivalent to the map form (section 9.1).
        if case .list(let items) = src {
            for item in items where try Refs.canonRef(item.at("ref")) == key {
                return item.get("options")
            }
            return nil
        }
        for k in src.keys where try Refs.canonRef(.str(k)) == key {
            let entry = src.at(k)
            return entry.isMap ? entry.get("options") : nil
        }
        return nil
    }

    /// Merge N levels below this key, replace below that.
    static func deepTo(_ base: Value, _ over: Value, _ n: Int) -> Value {
        if n <= 0 { return over }
        guard base.isMap, over.isMap else { return over }
        var out = base.asMap
        for k in over.keys { out[k] = deepTo(out[k] ?? .null, over.at(k), n - 1) }
        return .map(out)
    }

    /// Merge ONE layer onto the accumulator, honouring the shape's directives.
    /// The directive holds at EVERY precedence level, not only between document
    /// levels - section 9.4 makes it a property of the shape, which does not
    /// know which layer a value arrived from.
    static func mergeOne(_ base: Value, _ over: Value?, _ shape: Value) -> Value {
        guard let o = over else { return base }
        guard base.isMap, o.isMap else { return o }

        var out = base.asMap
        for k in o.keys {
            let ov = o.at(k)
            let bv = out[k] ?? .null
            let directive = shape.at(k).at("$MERGE")

            if directive == .str("replace") {
                out[k] = ov
            } else if directive == .str("append") {
                let bl = bv.isList ? bv.items : []
                let ol = ov.isList ? ov.items : [ov]
                out[k] = .list(bl + ol)
            } else if directive.has("deep") {
                out[k] = deepTo(bv, ov, directive.at("deep").asInt ?? 0)
            } else {
                // Library default: deep for maps, REPLACE for lists.
                // struct.merge is element-wise by index, which for option maps
                // is nearly always wrong - ["a"] over ["x","y","z"] yielding
                // ["a","y","z"] is the defect station hit on secrets.providers.
                out[k] = (bv.isMap && ov.isMap) ? mergeOne(bv, ov, .null) : ov
            }
        }
        return .map(out)
    }

    public static func resolveOptions(_ input: Value) throws -> Value {
        let shape = input.at("shape")
        try checkShape(shape)

        let ref = try Refs.canonRef(input.at("ref"))
        let name = Refs.refName(.str(ref))
        let doc = input.at("doc")
        let profile = input.at("profile")

        var overlay = Value.map([:])
        if let pname = profile.asString {
            let found = doc.at("profile").at(pname)
            if found.isMap { overlay = found }
        }

        // ONE ordered merge, lowest to highest. Levels 3-6 are not two
        // namespaces collapsed separately and composed afterwards: that inverts
        // the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION SPECIFICITY, so
        // a prod per-definition default would lose to a base instance value.
        let layers: [Value?] = [
            defaultsOf(shape),                                  // 1
            input.get("hostdefaults"),                          // 2
            try optsOf(doc.at("default"), name),                // 3
            try optsOf(doc.at("instance"), ref),                // 4
            try optsOf(overlay.at("default"), name),            // 5
            try optsOf(overlay.at("instance"), ref),            // 6
            input.get("env"),                                   // 7
            input.get("hostoptions"),                           // 8
            input.get("loadoptions"),                           // 9
            input.get("patch"),                                 // 10
        ]

        var out = Value.map([:])
        for layer in layers {
            guard let l = layer, !l.isNull else { continue }
            out = mergeOne(out, l, shape)
        }
        return out
    }
}
