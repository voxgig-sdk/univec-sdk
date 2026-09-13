// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/capability.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Capabilities (§11.1).
//!
//! A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
//! dependency on something that can do the job, and which instance is
//! doing it is exactly the configuration detail a plugin must not care
//! about. (§11.1 makes one narrow exception for a ref, and `host.zig`
//! implements it; the ranking here is capabilities only.)
//!
//! But A BINDING IS TO AN INSTANCE, not to a capability, which is what
//! decides behaviour when the bound provider leaves while another match
//! remains.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const version = @import("version.zig");

/// PARTIAL MATCH, RECURSING INTO MAPS (§11.1). THIS FUNCTION IS WHAT
/// "EVERY LEAF" MEANS, and an earlier draft of the canonical did not
/// have it: the check was a scalar compare, which for any compound value
/// is reference identity in JavaScript. A requirement and a capability
/// are declared in different places and are never the same object, so
/// `match: {limits: {max: 5}}` could not be satisfied by ANY provider —
/// including one declaring exactly that. Invisible while every corpus
/// entry is scalar, which is why the go port found it and P2 did not.
///
/// A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset —
/// "the first two of your three regions" is not something `match` can
/// say.
pub fn capmatchvalue(want: ?*v.Value, got: ?*v.Value) bool {
    if (v.isMap(want)) {
        if (!v.isMap(got)) return false;
        for (v.keys(want)) |k| {
            if (!v.has(got, k)) return false;
            if (!capmatchvalue(v.get(want, k), v.get(got, k))) return false;
        }
        return true;
    }
    if (v.isList(want)) {
        if (!v.isList(got) or v.len(want) != v.len(got)) return false;
        for (v.items(want), 0..) |x, i| {
            if (!capmatchvalue(x, v.at(got, i))) return false;
        }
        return true;
    }
    return v.same(want, got);
}

pub fn capmatches(req: ?*v.Value, prov: ?*v.Value) bool {
    if (!v.same(v.get(req, "name"), v.get(prov, "name"))) return false;

    const range = v.get(req, "range");
    if (!v.isNull(range)) {
        const ver = v.get(prov, "version");
        if (v.isNull(ver)) return false;
        if (!version.satisfiesq(ver, range)) return false;
    }

    // `match` is checked against the provider's `attrs`, key by key. A
    // key the provider does not carry is a MISS, not a pass: a
    // requirement asking for `transactional: true` must not be satisfied
    // by a provider that never said.
    const m = v.get(req, "match");
    if (!v.isNull(m)) {
        var attrs = v.get(prov, "attrs");
        if (v.isNull(attrs)) attrs = v.vmap();
        for (v.keys(m)) |k| {
            if (!v.has(attrs, k)) return false;
            if (!capmatchvalue(v.get(m, k), v.get(attrs, k))) return false;
        }
    }

    return true;
}

/// The rank key for one candidate. THE KEYS ARE PRECOMPUTED because the
/// version comparison is fallible and a zig sort comparator cannot be:
/// `parseversion` can fail, and a comparator that swallowed that would
/// have to guess. Precomputing also makes the rank a TOTAL order on
/// purpose — without one, "any provider satisfies" is true of the GRAPH
/// and useless to the PLUGIN, and two ports could bind different `store`
/// instances, both resolve green, and behave differently.
const RankKey = struct {
    noversion: u8, // a version beats none
    ver: [3]f64, // negated, so HIGHEST version sorts first
    priority: f64, // LOWEST priority first
    pos: f64,
    cand: *v.Value,
};

fn rankKey(c: *v.Value) RankKey {
    const p = v.get(c, "provides");
    const ver = v.get(p, "version");
    var key = RankKey{
        .noversion = if (v.isNull(ver)) 1 else 0,
        .ver = .{ 0, 0, 0 },
        .priority = if (v.isNum(v.get(p, "priority"))) v.asNum(v.get(p, "priority")) else 0,
        .pos = v.asNum(v.get(c, "pos")),
        .cand = c,
    };
    if (!v.isNull(ver)) {
        if (version.parseversion(ver)) |parsed| {
            var i: usize = 0;
            while (i < 3) : (i += 1) key.ver[i] = -v.asNum(v.at(parsed, i));
        } else |_| {
            _ = t.take();
        }
    }
    return key;
}

fn lessRank(_: void, a: RankKey, b: RankKey) bool {
    if (a.noversion != b.noversion) return a.noversion < b.noversion;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (a.ver[i] != b.ver[i]) return a.ver[i] < b.ver[i];
    }
    if (a.priority != b.priority) return a.priority < b.priority;
    return a.pos < b.pos;
}

/// Rank the matching providers best-first: highest `version`, then
/// LOWEST `priority` (default 0), then declaration position `pos`
/// ascending. `candidates` is a list of {ref, pos, provides}.
pub fn resolvecapability(req: ?*v.Value, candidates: ?*v.Value) *v.Value {
    var hits = v.List(RankKey).init(v.arena());
    for (v.items(candidates)) |c| {
        if (capmatches(req, v.get(c, "provides"))) hits.append(rankKey(c)) catch @panic("oom");
    }
    std.mem.sort(RankKey, hits.items, {}, lessRank);
    const out = v.vlist();
    for (hits.items) |h| v.push(out, h.cand);
    return out;
}
