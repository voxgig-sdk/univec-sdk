// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Refs.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Identity: name+tag, written `name$tag` (section 4).
///
/// The four pure functions, and the whole of what `ref` pins. They are the
/// first thing a new port implements and the first corpus section it passes.
public enum Refs {

    static let refMax = 1024

    /// Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
    ///
    /// A CHARACTER LOOP RATHER THAN A REGULAR EXPRESSION. Swift's stdlib has
    /// no regex on Linux - `NSRegularExpression` lives in Foundation, and this
    /// library imports Foundation nowhere - and a grammar this small is
    /// clearer as the two character classes it actually is. It also removes
    /// the whole `^`/`$`-versus-`\A`/`\z` trap that ruby, java and dart each
    /// document from a different side: there is no anchor to get wrong,
    /// because there is no search, and `"abc\n"` fails on the newline like any
    /// other character outside the class.
    public static func checkName(_ name: Value) -> Bool {
        guard let s = name.asString, !s.isEmpty, s.unicodeScalars.count <= refMax
        else { return false }
        var first = true
        for c in s.unicodeScalars {
            if first {
                guard isAlpha(c) || c == "@" else { return false }
                first = false
                continue
            }
            guard isAlpha(c) || isDigit(c) || c == "." || c == "~" ||
                c == "_" || c == "-" || c == "/" else { return false }
        }
        return true
    }

    /// Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
    ///
    /// The asymmetry with a name is deliberate: a tag MAY start with a digit
    /// because auto-tagging assigns integer tags (`stripe$1`), and a tag
    /// admits neither `@` nor `/` because a name is a package specifier and a
    /// tag is not.
    public static func checkTag(_ tag: Value) -> Bool {
        guard let s = tag.asString else { return false }
        // The empty tag is an ordinary tag (section 4 rule 2). The
        // single-instance case writes no tag and never learns tags exist.
        if s.isEmpty { return true }
        guard s.unicodeScalars.count <= refMax else { return false }
        for c in s.unicodeScalars {
            guard isAlpha(c) || isDigit(c) || c == "." || c == "~" ||
                c == "_" || c == "-" else { return false }
        }
        return true
    }

    static func isAlpha(_ c: Unicode.Scalar) -> Bool {
        return ("a" ... "z").contains(c) || ("A" ... "Z").contains(c)
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool {
        return ("0" ... "9").contains(c)
    }

    /// `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
    /// tag "".
    public static func parseRef(_ str: Value) throws -> Value {
        guard let s = str.asString else {
            throw Types.fail("plugin_bad_name", "ref must be a string")
        }
        // Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
        // in neither character class - so the corpus is the arbiter (section 4
        // rule 5), and it picks the split that blames the part actually at
        // fault: `a$b$c` is a good name with a bad tag, not the reverse.
        let scalars = Array(s.unicodeScalars)
        let cut = scalars.firstIndex(of: "$")
        let name = cut == nil ? s : String(String.UnicodeScalarView(scalars[0 ..< cut!]))
        let tag = cut == nil
            ? ""
            : String(String.UnicodeScalarView(scalars[(cut! + 1)...]))

        guard checkName(.str(name)) else {
            throw Types.fail(
                "plugin_bad_name", "invalid plugin name: \(name)", ["name": .str(name)]
            )
        }
        guard checkTag(.str(tag)) else {
            throw Types.fail(
                "plugin_bad_tag", "invalid plugin tag: \(tag)",
                ["name": .str(name), "tag": .str(tag)]
            )
        }
        return .map(["name": .str(name), "tag": .str(tag)])
    }

    /// The pair -> `name$tag`. An empty tag NEVER writes the separator, which
    /// is the half of canonicalization `formatRef` owns: parse tolerates
    /// `stripe$`, format never produces it, so a round trip is idempotent.
    public static func formatRef(_ name: Value, _ tag: Value = .null) throws -> String {
        let t = tag.isNull ? Value.str("") : tag
        guard checkName(name) else {
            throw Types.fail(
                "plugin_bad_name", "invalid plugin name: \(show(name))", ["name": name]
            )
        }
        guard checkTag(t) else {
            throw Types.fail(
                "plugin_bad_tag", "invalid plugin tag: \(show(t))",
                ["name": name, "tag": t]
            )
        }
        let n = name.asString!
        let ts = t.asString!
        return ts.isEmpty ? n : "\(n)$\(ts)"
    }

    /// A value as a message would show it: a string bare, anything else as
    /// JSON. Interpolating a `Value` directly would print the enum case.
    static func show(_ v: Value) -> String {
        return v.asString ?? v.json
    }

    /// The canonical spelling of a ref. Section 4 rule 5: ports must
    /// canonicalize before comparison.
    public static func canonRef(_ str: Value) throws -> String {
        let r = try parseRef(str)
        return try formatRef(r.at("name"), r.at("tag"))
    }

    /// `canonRef` for the internal callers that want the input back unchanged
    /// when it is not well formed. NEVER use it where a bad ref must be
    /// reported - the corpus pins plugin_bad_name at every public entry.
    public static func canon(_ str: Value) -> String {
        return (try? canonRef(str)) ?? (str.asString ?? str.json)
    }

    public static func refName(_ str: Value) -> String {
        if let r = try? parseRef(str), let n = r.at("name").asString { return n }
        return str.asString ?? str.json
    }
}
