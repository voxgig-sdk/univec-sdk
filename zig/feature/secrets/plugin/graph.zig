// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/graph.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Whole-graph resolution (§11.4) — a phase, not a discovery.
//!
//! "Activate, and wait in `pending` if you must" is correct and, on its
//! own, produces a terrible experience: apply twenty instances against a
//! registry missing one thing and you get NINETEEN pending rows and no
//! statement of what is actually wrong.
//!
//! `resolvegraph` is a PURE FUNCTION of the registry and the intended
//! activation set. No callbacks run, no state changes, nothing is
//! touched. It answers for the whole graph at once which instances can
//! be live, and for each blocked one THE SPECIFIC REQUIREMENT that is
//! unmet, and why.
//!
//! The failure mode being designed against is a famous one: OSGi's
//! resolver is correct and its diagnostics are legendarily unusable. A
//! resolver that says "blocked" without saying WHY has moved the problem
//! rather than solved it, so `why` is part of the contract.

const std = @import("std");
const v = @import("value.zig");
const cap = @import("capability.zig");
const ref = @import("ref.zig");
const version = @import("version.zig");

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn sortedStrings(list: [][]const u8) *v.Value {
    std.mem.sort([]const u8, list, {}, lessStr);
    const out = v.vlist();
    for (list) |s| v.push(out, v.vstr(s));
    return out;
}

fn candidates(byref: *v.Value, name: ?*v.Value) *v.Value {
    const out = v.vlist();
    // A NODE SATISFIES ITS OWN REF (§11.1), and this is where the graph
    // learned it. Considering only declared capabilities made `resolve`
    // answer `absent` about a provider sitting right there and live —
    // §11.4's whole job is explaining the graph the runtime reconciles,
    // and it was explaining a different one. Canonical (§4 rule 5), and
    // tolerant, because a capability name need not be a well-formed ref.
    const asref = if (v.isStr(name)) ref.tryref(v.asStr(name)) else null;

    for (v.sortedKeys(byref)) |r| {
        const node = v.get(byref, r);
        var pos = v.get(node, "pos");
        if (!v.isNum(pos)) pos = v.vnum(0);
        // The ref match WINS OUTRIGHT for that node, as at runtime: one
        // candidate, not two, for a node both named `b` and providing
        // `b` — without the skip the blocked-chain explanation named it
        // twice.
        if (asref != null and std.mem.eql(u8, r, asref.?)) {
            const prov = v.vmap();
            v.set(prov, "name", name);
            const c = v.vmap();
            v.set(c, "ref", v.get(node, "ref"));
            v.set(c, "pos", pos);
            v.set(c, "provides", prov);
            v.push(out, c);
            continue;
        }
        for (v.items(v.get(node, "provides"))) |p| {
            if (v.same(v.get(p, "name"), name)) {
                const c = v.vmap();
                v.set(c, "ref", v.get(node, "ref"));
                v.set(c, "pos", pos);
                v.set(c, "provides", p);
                v.push(out, c);
            }
        }
    }
    return out;
}

fn blockedof(node: ?*v.Value, unmet: ?*v.Value, why: ?*v.Value) *v.Value {
    const out = v.vmap();
    v.set(out, "ref", v.get(node, "ref"));
    v.set(out, "unmet", unmet);
    v.set(out, "why", why);
    return out;
}

fn why1(kind: []const u8) *v.Value {
    const w = v.vmap();
    v.set(w, "kind", v.vstr(kind));
    return w;
}

/// The FIRST unmet requirement, with the most specific explanation
/// available. Order matters: "no provider at all" and "a provider at the
/// wrong version" are different problems and a reader must not have to
/// guess which they have.
fn firstunmet(node: *v.Value, byref: *v.Value, resolved: *v.Value) ?*v.Value {
    for (v.items(v.get(node, "requires"))) |req| {
        if (v.truthy(v.get(req, "optional"))) continue;

        const name = v.get(req, "name");
        const all = candidates(byref, name);
        if (v.len(all) == 0) return blockedof(node, name, why1("absent"));

        const ok = cap.resolvecapability(req, all);
        if (v.len(ok) > 0) {
            // A provider exists and matches — but if none of them is
            // itself resolved, this node is blocked BEHIND it, and the
            // chain is the useful answer rather than "unmet".
            var live = false;
            for (v.items(ok)) |c| {
                if (v.has(resolved, v.asStr(v.get(c, "ref")))) {
                    live = true;
                    break;
                }
            }
            if (live) continue;

            var chain = v.List([]const u8).init(v.arena());
            for (v.items(ok)) |c| chain.append(v.asStr(v.get(c, "ref"))) catch @panic("oom");
            const w = why1("blocked");
            v.set(w, "chain", sortedStrings(chain.items));
            return blockedof(node, name, w);
        }

        // Providers exist and none matched. Say which test failed.
        const range = v.get(req, "range");
        if (!v.isNull(range)) {
            var found = v.List([]const u8).init(v.arena());
            for (v.items(all)) |c| {
                const ver = v.get(v.get(c, "provides"), "version");
                if (v.isNull(ver)) {
                    found.append("(none)") catch @panic("oom");
                } else if (!version.satisfiesq(ver, range)) {
                    found.append(v.asStr(ver)) catch @panic("oom");
                }
            }
            if (found.items.len > 0) {
                const w = why1("version");
                v.set(w, "range", range);
                v.set(w, "found", sortedStrings(found.items));
                return blockedof(node, name, w);
            }
        }

        const m = v.get(req, "match");
        if (!v.isNull(m)) {
            for (v.items(all)) |c| {
                var attrs = v.get(v.get(c, "provides"), "attrs");
                if (v.isNull(attrs)) attrs = v.vmap();
                for (v.sortedKeys(m)) |k| {
                    // The same recursive partial match the selection
                    // applies, so a nested requirement that FAILED the
                    // selection is also the one the diagnosis names
                    // (§11.4).
                    if (!v.has(attrs, k) or !cap.capmatchvalue(v.get(m, k), v.get(attrs, k))) {
                        const w = why1("match");
                        v.set(w, "failing", v.vstr(k));
                        v.set(w, "want", v.get(m, k));
                        v.set(w, "found", v.get(attrs, k));
                        return blockedof(node, name, w);
                    }
                }
            }
        }

        return blockedof(node, name, why1("absent"));
    }
    return null;
}

pub fn resolvegraph(nodes: ?*v.Value) *v.Value {
    const byref = v.vmap();
    for (v.items(nodes)) |n| v.set(byref, v.asStr(v.get(n, "ref")), n);

    const resolved = v.vmap();

    // Fixed point: a node resolves when every mandatory requirement is
    // met by an ALREADY-RESOLVED provider. Iterating to a fixed point is
    // what makes a provider that is itself blocked propagate, rather
    // than each node being judged against the raw registry.
    var moved = true;
    while (moved) {
        moved = false;
        for (v.items(nodes)) |n| {
            const r = v.asStr(v.get(n, "ref"));
            if (v.has(resolved, r)) continue;
            if (firstunmet(n, byref, resolved) == null) {
                v.set(resolved, r, v.vbool(true));
                moved = true;
            }
        }
    }

    const blocked = v.vmap();
    for (v.items(nodes)) |n| {
        const r = v.asStr(v.get(n, "ref"));
        if (v.has(resolved, r)) continue;
        if (firstunmet(n, byref, resolved)) |why| v.set(blocked, r, why);
    }

    const resolvedlist = v.vlist();
    for (v.sortedKeys(resolved)) |k| v.push(resolvedlist, v.vstr(k));
    const blockedlist = v.vlist();
    for (v.sortedKeys(blocked)) |k| v.push(blockedlist, v.get(blocked, k));

    const out = v.vmap();
    v.set(out, "resolved", resolvedlist);
    v.set(out, "blocked", blockedlist);
    return out;
}
