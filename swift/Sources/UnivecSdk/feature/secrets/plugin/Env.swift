// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Env.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Environment overrides (section 9.5) - level 7 of the ladder.
///
/// One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
///
///   VOXGIG_PLUGIN_PROFILE            the profile name
///   VOXGIG_PLUGIN_<REF>_<PATH>       one option
///   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
///
/// THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING OTHERWISE.
/// Ref and path are upper-snake with `$` -> `__` and `.` -> `_`. But `_` is
/// legal in a name and in a tag, and the mapping folds case, so `retry$fast`
/// and `retry__fast` both encode to `RETRY__FAST`.
///
/// Rather than restrict a grammar the rest of the stack already uses, the host
/// DETECTS THE COLLISION: it encodes every ref it holds, and a key two refs
/// claim is `plugin_env_ambiguous`, naming both.
public enum Env {

    static let prefix = "VOXGIG_PLUGIN_"

    /// `retry$fast` -> `RETRY__FAST`.
    public static func encodeRef(_ ref: String) -> String {
        return ref.replacingOccurrences(of: "$", with: "__")
            .replacingOccurrences(of: ".", with: "_")
            .uppercased()
    }

    /// Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
    /// `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
    /// looks like rather than a parse error.
    static func parseValue(_ value: Value) -> Value {
        guard let s = value.asString else { return value }
        return (try? Json.parse(s)) ?? value
    }

    static func split(_ value: Value) -> [String] {
        let text = value.asString ?? value.json
        return text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    static func checkReserved(_ ref: String, _ reserved: Value) throws {
        guard reserved.items.contains(.str(Refs.refName(.str(ref)))) else { return }
        throw Types.fail(
            "plugin_ref_reserved", "ref is reserved by the host: \(ref)",
            ["ref": .str(ref)]
        )
    }

    public static func applyEnv(_ input: Value) throws -> Value {
        let env = input.at("env")
        let refs = try input.at("refs").items.map { try Refs.canonRef($0) }
        let reserved = input.at("reserved")

        var options: [String: Value] = [:]
        var active: [Value] = []
        var inactive: [Value] = []
        var profile: Value?

        // Encode every ref the host holds, and refuse a key that two of them
        // claim. Done up front so the collision is reported even when no
        // environment variable exercises it - a latent ambiguity is still an
        // ambiguity, and finding it at deploy time is the failure this exists to
        // prevent.
        var byencoded: [String: [String]] = [:]
        for ref in refs { byencoded[encodeRef(ref), default: []].append(ref) }
        for e in byencoded.keys.sorted() where byencoded[e]!.count > 1 {
            let pair = byencoded[e]!.sorted()
            throw Types.fail(
                "plugin_env_ambiguous",
                "refs collide in the environment encoding as \(e): "
                    + pair.joined(separator: ", "),
                ["encoded": .str(e), "refs": .list(pair.map { .str($0) })]
            )
        }

        // Longest encoded ref first, so `retry$fast` wins over `retry` on
        // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
        let encoded = Types.stableSortBy(byencoded.keys.sorted()) {
            [SortKey.num(Double(-$0.count))]
        }

        for key in env.keys {
            guard key.hasPrefix(prefix) else { continue }
            let rest = String(key.dropFirst(prefix.count))

            if rest == "PROFILE" {
                profile = env.at(key)
                continue
            }

            if rest == "ACTIVE" || rest == "INACTIVE" {
                for raw in split(env.at(key)) {
                    let ref = try Refs.canonRef(.str(raw))
                    // The reservation covers EVERY input layer (section 9.1).
                    // VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                    // editing a config file, and INACTIVE has the final word -
                    // so guarding documents alone would leave the one lever this
                    // mechanism exists to deny wide open.
                    try checkReserved(ref, reserved)
                    if rest == "ACTIVE" { active.append(.str(ref)) }
                    else { inactive.append(.str(ref)) }
                }
                continue
            }

            guard let enc = encoded.first(where: { rest == $0 || rest.hasPrefix($0 + "_") })
            else { continue } // not for any ref this host holds

            let ref = byencoded[enc]![0]
            try checkReserved(ref, reserved)

            if rest == enc { continue } // a ref with no path sets nothing

            let path = String(rest.dropFirst(enc.count + 1)).lowercased()
                .split(separator: "_", omittingEmptySubsequences: false).map(String.init)

            options[ref] = write(options[ref] ?? .map([:]), path, parseValue(env.at(key)))
        }

        var out: [String: Value] = [
            "options": .map(options),
            "active": .list(active),
            "inactive": .list(inactive),
        ]
        if let p = profile { out["profile"] = p }
        return .map(out)
    }

    /// Write one option at a dotted path, creating maps as it goes. A step whose
    /// current value is not a map is REPLACED, because a scalar written by a
    /// shallower variable cannot also be a container.
    static func write(_ node: Value, _ path: [String], _ value: Value) -> Value {
        let base = node.isMap ? node : .map([:])
        if path.count == 1 { return base.setting(path[0], value) }
        let child = base.at(path[0])
        return base.setting(path[0], write(child, Array(path.dropFirst()), value))
    }
}

extension Substring {
    var trimmed: String {
        var s = self
        while let f = s.first, f == " " || f == "\t" || f == "\n" || f == "\r" {
            s = s.dropFirst()
        }
        while let l = s.last, l == " " || l == "\t" || l == "\n" || l == "\r" {
            s = s.dropLast()
        }
        return String(s)
    }
}

extension String {
    /// The library imports no Foundation, so the two string replacements
    /// `encodeRef` needs are written here rather than taken from it.
    func replacingOccurrences(of needle: String, with replacement: String) -> String {
        guard !needle.isEmpty else { return self }
        var out = ""
        var rest = Substring(self)
        while let r = rest.range(of: needle) {
            out += rest[rest.startIndex ..< r.lowerBound]
            out += replacement
            rest = rest[r.upperBound...]
        }
        return out + rest
    }
}

extension Substring {
    func range(of needle: String) -> Range<Index>? {
        let n = Array(needle)
        guard !n.isEmpty else { return nil }
        var i = startIndex
        while i < endIndex {
            var j = i
            var k = 0
            while k < n.count, j < endIndex, self[j] == n[k] {
                j = index(after: j)
                k += 1
            }
            if k == n.count { return i ..< j }
            i = index(after: i)
        }
        return nil
    }
}
