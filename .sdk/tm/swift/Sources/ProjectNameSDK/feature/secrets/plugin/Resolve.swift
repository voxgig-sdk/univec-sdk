// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Resolve.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Dynamic resolution (section 10.2) - name to candidate module ids.
///
/// PURE. It returns the ids a host WOULD try, in order; it does not load
/// anything. That separation is what lets the corpus pin resolution in every
/// language including those with no dynamic loading at all, and it is why
/// section 15.4 puts real module loading in per-port integration tests rather
/// than here.
public enum Resolve {

    public static let defaultSources: Value = .list([
        .map([
            "kind": .str("module"),
            "prefix": .list([
                .str("@voxgig/plugin-"), .str("voxgig-plugin-"),
                .str("plugin-"), .str(""),
            ]),
        ]),
    ])

    public static func resolveCandidates(_ name: String, _ sources: Value = .null) -> [String] {
        // A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing` is
        // already a package id; prefixing it produces
        // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
        if name.hasPrefix("@") { return [name] }

        let list = sources.items.isEmpty ? defaultSources : sources
        var out: [String] = []

        for src in list.items {
            switch src.at("kind").asString {
            case "module":
                var prefixes = src.at("prefix").items
                if prefixes.isEmpty { prefixes = [.str("")] }
                for p in prefixes {
                    let id = (p.asString ?? "") + name
                    if !out.contains(id) { out.append(id) }
                }
            case "path":
                var dir = src.at("dir").asString ?? ""
                while dir.hasSuffix("/") { dir = String(dir.dropLast()) }
                let id = "\(dir)/\(name)"
                if !out.contains(id) { out.append(id) }
            default:
                continue
            }
        }
        return out
    }

    /// A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a
    /// name with a letter or `@`, so `./local/thing` is not a ref and never
    /// reaches candidate generation - seneca allows a path where a plugin name
    /// goes, and this design deliberately does not, because a ref is an ADDRESS
    /// WITHIN A HOST and a path is a LOCATION ON A DISK.
    public static func resolveFrom(_ from: Value) -> [Value] { return [from] }
}
