// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Capability.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Capabilities (section 11.1).
///
/// A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a dependency
/// on something that can do the job, and which instance is doing it is exactly
/// the configuration detail a plugin must not care about.
///
/// But A BINDING IS TO AN INSTANCE, not to a capability, which is what decides
/// behaviour when the bound provider leaves while another match remains.
public enum Capability {

    /// Rank the matching live providers and return them best-first: highest
    /// `version`, then LOWEST `priority` (default 0), then declaration position
    /// `pos` ascending.
    ///
    /// `priority` is a field on the capability rather than section 7's `order`
    /// band, because bands live on POINT BINDINGS: a provider may have several
    /// bindings with different bands, or none at all, so a rank reaching for one
    /// would be undefined in the common case.
    ///
    /// Without a total rank, "any provider satisfies" is true of the GRAPH and
    /// useless to the PLUGIN - two ports could bind different `store` instances,
    /// both resolve green, and behave differently, which is precisely the
    /// divergence a shared corpus exists to catch.
    public static func resolveCapability(_ req: Value, _ candidates: Value) -> [Value] {
        let hits = candidates.items.filter { matches(req, $0.at("provides")) }
        return Types.stableSortBy(hits) { rankKey($0) }
    }

    /// An ABSENT version sorts LAST, whatever the other is - "no version" loses
    /// to every version rather than being read as 0.0.0. The leading flag is
    /// what expresses that in a sort KEY rather than a comparator.
    public static func rankKey(_ cand: Value) -> [SortKey] {
        let prov = cand.at("provides")
        let version = prov.get("version")
        let absent = version == nil || version!.isNull
        return [
            .num(absent ? 1 : 0),
            .list(absent
                ? [.num(0), .num(0), .num(0)]
                : Version.versionParts(version!).map { SortKey.num(-$0) }),
            .num(prov.at("priority").asDouble ?? 0),
            .num(cand.at("pos").asDouble ?? 0),
        ]
    }

    public static func matches(_ req: Value, _ prov: Value) -> Bool {
        if req.at("name") != prov.at("name") { return false }

        if let range = req.get("range"), !range.isNull {
            guard let version = prov.get("version"), !version.isNull else { return false }
            if !Version.satisfiesq(version, range) { return false }
        }

        // `match` is checked against the provider's `attrs`, key by key. A key
        // the provider does not carry is a miss, not a pass: a requirement
        // asking for `transactional: true` must not be satisfied by a provider
        // that never said.
        if let want = req.get("match"), !want.isNull {
            let attrs = prov.at("attrs")
            for k in want.keys {
                guard attrs.has(k) else { return false }
                if !matchValue(want.at(k), attrs.at(k)) { return false }
            }
        }
        return true
    }

    /// PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
    ///
    /// Every leaf in the requirement must be present and equal in the
    /// capability, keys not mentioned are not checked. Equality is by JSON TYPE
    /// as well as value: `transactional: 1` does not satisfy
    /// `transactional: true`. SWIFT NEEDS NO GUARD FOR THAT - `Value` is an
    /// enum, and `.bool(true)` and `.num(1)` are different cases that cannot
    /// compare equal however hard a reading tries. Python, PHP, Perl and Lua
    /// all need one, and `capability/match` pins the behaviour for every port
    /// rather than trusting each language's equality.
    ///
    /// A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
    public static func matchValue(_ want: Value, _ got: Value) -> Bool {
        if case .map = want {
            guard case .map = got else { return false }
            for k in want.keys {
                guard got.has(k) else { return false }
                if !matchValue(want.at(k), got.at(k)) { return false }
            }
            return true
        }
        if case .list(let w) = want {
            guard case .list(let g) = got, w.count == g.count else { return false }
            return zip(w, g).allSatisfy { matchValue($0, $1) }
        }
        return want == got
    }
}
