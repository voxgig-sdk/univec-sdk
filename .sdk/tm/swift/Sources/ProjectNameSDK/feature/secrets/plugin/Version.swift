// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Version.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Versions and ranges (section 11.2).
///
/// TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
/// version. A requirement declares `range`. A requirement is satisfied when the
/// names match, the `match` passes, and the provider's `version` falls inside
/// the requirement's `range`.
///
/// That is the whole rule. There is no third field and no second comparison -
/// an earlier draft added a provider-side `compat` range, which left three
/// values and no statement of how they combine, and three defensible readings
/// of one declaration is worse than the ambiguity it was introduced to fix.
public enum Version {

    /// A COMPONENT IS BOUNDED, and the bound is the model's, not the host
    /// language's. A swift `Int` is 64-bit and javascript stops being exact
    /// past 2**53, so `9223372036854775808.0.0` parsed to an exact value here
    /// and a rounded one there. 2**31-1 is the smallest bound every target
    /// language holds exactly, which makes it the model's.
    public static let componentMax: Double = 2147483647

    /// The three dot-separated numeric parts, or nil - written as a scan for
    /// the same reason `Refs` is: no regex, and nothing to get wrong about
    /// anchoring.
    static func scan(_ s: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        for c in s.unicodeScalars {
            if Refs.isDigit(c) {
                current.unicodeScalars.append(c)
                continue
            }
            if c == "." {
                if current.isEmpty { return nil }
                parts.append(current)
                current = ""
                continue
            }
            return nil
        }
        if current.isEmpty { return nil }
        parts.append(current)
        return parts.count <= 3 ? parts : nil
    }

    /// A component parses as a `Double` so that `major + 1` at `componentMax`
    /// is 2147483648 rather than an overflow, and so that every number in this
    /// port is one type.
    static func component(_ digits: String, _ whole: String, _ field: String) throws -> Double {
        // Leading zeros and forty digits both have to survive this, so the
        // parse is on the digit string rather than on an `Int`.
        guard let value = Double(digits) else {
            throw Types.fail(
                "plugin_bad_range", "invalid \(field): \(whole)", [field: .str(whole)]
            )
        }
        if componentMax < value {
            throw Types.fail(
                "plugin_bad_range",
                "version component out of range in \(whole): \(digits)",
                [field: .str(whole)]
            )
        }
        return value
    }

    /// Two forms and no more (section 11.2):
    ///
    ///   '2.1'    >= 2.1.0 and < 3.0.0
    ///   '~2.1'   >= 2.1.0 and < 2.2.0
    public static func parseRange(_ range: Value) throws -> Value {
        guard let s = range.asString, !s.isEmpty else {
            throw Types.fail(
                "plugin_bad_range", "invalid range: \(Refs.show(range))", ["range": range]
            )
        }
        let tilde = s.hasPrefix("~")
        let body = tilde ? String(s.dropFirst()) : s
        guard let parts = scan(body) else {
            throw Types.fail("plugin_bad_range", "invalid range: \(s)", ["range": range])
        }
        let major = try component(parts[0], s, "range")
        let minor = parts.count > 1 ? try component(parts[1], s, "range") : 0
        let patch = parts.count > 2 ? try component(parts[2], s, "range") : 0

        return .map([
            "lo": .list([.num(major), .num(minor), .num(patch)]),
            "hi": tilde
                ? .list([.num(major), .num(minor + 1), .num(0)])
                : .list([.num(major + 1), .num(0), .num(0)]),
        ])
    }

    public static func parseVersion(_ version: Value) throws -> [Double] {
        guard let s = version.asString, let parts = scan(s) else {
            throw Types.fail(
                "plugin_bad_range", "invalid version: \(Refs.show(version))",
                ["version": version]
            )
        }
        return [
            try component(parts[0], s, "version"),
            parts.count > 1 ? try component(parts[1], s, "version") : 0,
            parts.count > 2 ? try component(parts[2], s, "version") : 0,
        ]
    }

    public static func versionCmp(_ a: [Double], _ b: [Double]) -> Int {
        for i in 0 ..< 3 {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// The one satisfaction predicate: lo <= version < hi.
    public static func satisfies(_ version: Value, _ range: Value) throws -> Bool {
        let v = try parseVersion(version)
        let r = try parseRange(range)
        let lo = r.at("lo").items.compactMap { $0.asDouble }
        let hi = r.at("hi").items.compactMap { $0.asDouble }
        return versionCmp(v, lo) >= 0 && versionCmp(v, hi) < 0
    }

    /// `satisfies` for the internal callers that treat an unparseable version
    /// or range as "does not satisfy" - Capability and Graph, both of which run
    /// over data the corpus has already admitted.
    public static func satisfiesq(_ version: Value, _ range: Value) -> Bool {
        return (try? satisfies(version, range)) ?? false
    }

    /// The numeric parts of a version, or zeros - a SORT KEY, never a check.
    public static func versionParts(_ text: Value) -> [Double] {
        return (try? parseVersion(text)) ?? [0, 0, 0]
    }
}
