// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Types.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The error type, the sort key, and the handful of helpers every module needs.
///
/// EVERY FUNCTION THAT CAN FAIL IS `throws`, and that is this port's defining
/// cost. Rust returns a `Result` and the other ports raise; swift makes the
/// possibility part of the signature, so `try` appears at every call in the
/// chain from `Host.ready` down to `Refs.parseRef`. It is verbose and it is
/// honest: a reader can see from a signature alone whether a call can produce
/// a section 12 error.

/// Every error carries a section 12 code. Ports compare by CODE and never by
/// message: wording is a port's own business, and pinning the words would make
/// every translation a corpus change. The FORMAT, however, is pinned - a
/// parseable message is what makes a log searchable across twenty languages.
public struct PluginError: Error {
    public let code: String
    public let text: String
    public let details: [String: Value]
    public let message: String

    public init(_ code: String, _ text: String, _ details: [String: Value]) {
        self.code = code
        self.text = text
        self.details = details
        self.message = Types.formatError(code, text, details)
    }
}

public enum Types {

    /// Section 5.1's seven statuses, and no more.
    public static let statuses = [
        "declared", "loaded", "pending", "live", "failed", "loading", "closing"
    ]

    /// Section 12's detail keys, in the order a message renders them. FIXED,
    /// not the map's: a message is a searchable log line, and a line whose
    /// fields move between runs is not.
    public static let detailOrder = [
        "ref", "point", "name", "key", "spec", "refs", "kind", "directive",
        "cycle", "holders", "cause"
    ]

    /// `plugin/<code>: <text> [<key>=<value> ...]`
    ///
    /// Values render as COMPACT JSON, so a value containing a space or a
    /// bracket cannot break the parse, and a list renders as a JSON array. The
    /// bracket is absent entirely when no field applies.
    public static func formatError(
        _ code: String, _ text: String, _ details: [String: Value]
    ) -> String {
        let parts = detailOrder.compactMap { k -> String? in
            guard let v = details[k] else { return nil }
            return "\(k)=\(v.json)"
        }
        let tail = parts.isEmpty ? "" : " [" + parts.joined(separator: " ") + "]"
        return "plugin/\(code): \(text)\(tail)"
    }

    /// Throw a section 12 error. One spelling, so every raise site reads the
    /// same.
    public static func fail(
        _ code: String, _ text: String, _ details: [String: Value] = [:]
    ) -> PluginError {
        return PluginError(code, text, details)
    }

    /// The section 12 code of an error, or "" for one this library did not
    /// throw. The corpus compares by code, so the driver needs one place that
    /// knows how to read it.
    public static func codeOf(_ e: Error) -> String {
        return (e as? PluginError)?.code ?? ""
    }

    public static func messageOf(_ e: Error) -> String {
        return (e as? PluginError)?.message ?? "\(e)"
    }

    /// A STABLE sort by a comparable key.
    ///
    /// SWIFT'S `sort` IS NOT GUARANTEED STABLE. It is a timsort today and
    /// stable in every size this port has measured, and the documentation
    /// declines to promise it - which makes relying on it a bet on an
    /// implementation detail. Section 7's comparators fall through to a `pos`
    /// or ref tie-break that javascript's stable sort resolves BY POSITION, so
    /// the guarantee has to come from here: decorate with the original index
    /// and break the last tie on it.
    public static func stableSortBy<T>(_ list: [T], _ keyOf: (T) -> [SortKey]) -> [T] {
        return list.enumerated()
            .map { (keyOf($0.element), $0.offset, $0.element) }
            .sorted { a, b in
                let c = SortKey.compare(a.0, b.0)
                return c != 0 ? c < 0 : a.1 < b.1
            }
            .map { $0.2 }
    }
}

/// A sort key element. A key is a list of numbers, strings and nested lists,
/// which is what lets `Capability.rankKey` express "absent version sorts last"
/// as a leading flag rather than as a comparator.
public enum SortKey {
    case num(Double)
    case text(String)
    case list([SortKey])

    public static func compare(_ a: [SortKey], _ b: [SortKey]) -> Int {
        for i in 0 ..< Swift.min(a.count, b.count) {
            let c = compareOne(a[i], b[i])
            if c != 0 { return c }
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    static func compareOne(_ a: SortKey, _ b: SortKey) -> Int {
        switch (a, b) {
        case (.num(let x), .num(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        case (.text(let x), .text(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        case (.list(let x), .list(let y)): return compare(x, y)
        default: return 0
        }
    }
}
