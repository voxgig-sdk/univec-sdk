// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Value.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The JSON value, and the only parser this port has.
///
/// NO FOUNDATION IN THE LIBRARY, AND NO SWIFTPM DEPENDENCIES (section 16).
/// The library is allowed exactly one runtime dependency, `voxgig/struct`,
/// which has no swift port; everything else is the standard library.
/// `JSONSerialization` would have cost an `import Foundation` in every file
/// that touches a value, and it hands back `[String: Any]` with `NSNull` -
/// which is the untyped model swift exists to avoid.
///
/// A `Value` IS AN ENUM, not `Any`. Swift can express the JSON model exactly,
/// and `[String: Any]` would throw away every guarantee the language is for:
/// `dict["k"] = nil` REMOVES the key rather than storing a null, so an
/// authored null and an absent key - the distinction `__NULL__` and
/// `__UNDEF__` pin - could not be told apart at all.
///
/// `.num` is a `Double` because JSON HAS ONE NUMBER TYPE. The canonical is
/// javascript, `1` and `1.0` are the same value there, and a port that split
/// them would disagree with the corpus on which of two spellings a document
/// used.
public enum Value {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case list([Value])
    case map([String: Value])

    /// A host object published through `exports` (section 11). The design lets
    /// a plugin export "a client" - a thing the library never inspects - and
    /// in a statically typed port that needs an escape hatch. It is never
    /// produced by the parser and never compared as data.
    case opaque(AnyObject)
}

// MARK: - reading

public extension Value {

    /// The value at a key, or nil. `nil` is ABSENT; `.null` is a present null,
    /// and that is the whole reason this returns an optional rather than
    /// `.null` for both.
    func get(_ key: String) -> Value? {
        if case .map(let m) = self { return m[key] }
        return nil
    }

    /// PRESENCE, which is what distinguishes an authored null from absence.
    func has(_ key: String) -> Bool { return get(key) != nil }

    /// The value at a key with an absent key flattened to `.null` - for the
    /// many sites that treat the two alike.
    func at(_ key: String) -> Value { return get(key) ?? .null }

    /// The keys of a map, SORTED - every walk of a map goes through here. A
    /// swift `Dictionary` has NO ORDER AT ALL, not even insertion order, so
    /// this is not tidiness: without it a teardown order changes between two
    /// runs of the same process.
    var keys: [String] {
        if case .map(let m) = self { return m.keys.sorted() }
        return []
    }

    var items: [Value] {
        if case .list(let l) = self { return l }
        return []
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    var isMap: Bool { if case .map = self { return true }; return false }

    var isList: Bool { if case .list = self { return true }; return false }

    var asString: String? { if case .str(let s) = self { return s }; return nil }

    var asDouble: Double? { if case .num(let n) = self { return n }; return nil }

    var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }

    var asMap: [String: Value] { if case .map(let m) = self { return m }; return [:] }

    /// An INTEGER, and only when the value is one. Section 7's band is an
    /// integer the document wrote as one, and every number here is a `Double`,
    /// so the test is "a whole double" - `true` and `"2"` are neither and
    /// reach neither branch.
    var asInt: Int? {
        guard case .num(let n) = self, n == n.rounded(.down), n.isFinite else { return nil }
        return Int(n)
    }

    /// JSON truthiness: null and false, and nothing else, are false. Swift has
    /// no truthiness of its own - `if 0` does not compile - so this is where
    /// the model's rule is written down.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        default: return true
        }
    }
}

// MARK: - writing

public extension Value {

    /// COMPACT JSON, map keys in sorted order. A whole double renders WITHOUT
    /// its fraction, so `1.0` and `1` spell the same - the corpus writes both
    /// and a message quoting one must not depend on which.
    var json: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .num(let n):
            return (n == n.rounded(.down) && n.isFinite) ? String(Int(n)) : String(n)
        case .str(let s): return Value.quote(s)
        case .list(let l): return "[" + l.map { $0.json }.joined(separator: ",") + "]"
        case .map:
            let body = keys.map { Value.quote($0) + ":" + at($0).json }
            return "{" + body.joined(separator: ",") + "}"
        case .opaque: return "\"(opaque)\""
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += "\\u" + Value.hex4(c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }

    static func hex4(_ v: UInt32) -> String {
        let digits = "0123456789abcdef".map { $0 }
        var out = ""
        for shift in [12, 8, 4, 0] {
            out.append(digits[Int((v >> UInt32(shift)) & 0xF)])
        }
        return out
    }
}

// MARK: - equality

extension Value: Equatable {

    /// JSON equality: same type, then same value. Written out rather than
    /// synthesized, because `.opaque` holds an `AnyObject` that is not
    /// `Equatable` and because the rule the corpus needs is a type-strict one -
    /// `true` does not equal `1`, which a synthesized `==` would also give but
    /// only by accident of the enum's shape.
    public static func == (a: Value, b: Value) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.num(let x), .num(let y)): return x == y
        case (.str(let x), .str(let y)): return x == y
        case (.list(let x), .list(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
        case (.map(let x), .map(let y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { v == $0 } ?? false }
        case (.opaque(let x), .opaque(let y)): return x === y
        default: return false
        }
    }
}

// MARK: - building

public extension Value {

    static func mapOf(_ pairs: [String: Value]) -> Value { return .map(pairs) }

    static func listOf(_ items: [Value]) -> Value { return .list(items) }

    /// Set a key, returning the new value. A `Value` is a VALUE - the enum is
    /// copied - so every mutation is explicit and nothing aliases.
    func setting(_ key: String, _ value: Value) -> Value {
        var m = asMap
        m[key] = value
        return .map(m)
    }
}
