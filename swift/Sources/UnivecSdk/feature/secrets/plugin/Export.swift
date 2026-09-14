// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Export.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Exports (section 11).
///
/// An instance publishes values for other plugins and for the application.
/// Read with `host.exports("retry$fast/client")`.
///
/// THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves to
/// the UNTAGGED instance if one exists; if not, and exactly one tagged instance
/// exports that key, it resolves to that one; if two do, it is
/// `plugin_export_ambiguous` - deliberately diverging from seneca's silent
/// last-wins, because with multi-instance as a headline feature an ambiguous
/// alias is a defect waiting for production.
public enum Export {

    /// One published value. An internal shape, never a corpus value.
    public struct Exported {
        public let ref: String
        public let key: String
        public let value: Value

        public init(_ ref: String, _ key: String, _ value: Value) {
            self.ref = ref
            self.key = key
            self.value = value
        }
    }

    public static func resolveExport(_ spec: String, _ exported: [Exported]) throws -> Value {
        guard let cut = spec.firstIndex(of: "/") else {
            throw Types.fail(
                "plugin_export_ambiguous", "export spec needs a key: \(spec)",
                ["spec": .str(spec)]
            )
        }
        let head = String(spec[spec.startIndex ..< cut])
        let key = String(spec[spec.index(after: cut)...])

        // A fully qualified ref: exactly one answer or none.
        let want = Refs.canon(.str(head))
        for e in exported where e.ref == want && e.key == key { return e.value }

        // An alias: the name, not a ref. Look at every instance of it.
        let byname = exported.filter { Refs.refName(.str($0.ref)) == head && $0.key == key }
        if byname.isEmpty { return .null }

        for e in byname {
            if let parsed = try? Refs.parseRef(.str(e.ref)),
               parsed.at("tag").asString == "" {
                return e.value
            }
        }
        if byname.count == 1 { return byname[0].value }

        let refs = byname.map { $0.ref }.sorted()
        throw Types.fail(
            "plugin_export_ambiguous",
            "alias \(spec) matches \(refs.count) instances: \(refs.joined(separator: ", "))",
            ["spec": .str(spec), "refs": .list(refs.map { .str($0) })]
        )
    }
}
