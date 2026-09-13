// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/order.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Ordering (§7) — one rule, one place.
//!
//! sdkgen grew two special cases in `makeOptions` (`test`, then
//! `station`) and the third was not far off. This sort is the whole
//! replacement, and the tiers are in this order for a reason:
//!
//!   1 constraints   before/after edges, by ref or by name
//!   2 bands         integer, lower first, default 0
//!   3 declaration   ties break by `pos`
//!
//! CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both
//! are present. A band expresses a genuine cross-cutting layer; a
//! constraint expresses a relationship between two specific things; and
//! a band chosen by trial and error to fix an ordering bug is a bug
//! wearing a number.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const ref = @import("ref.zig");

/// A NUMBER, not a numeric string. `order.band` accepting "1" was a
/// surviving mutation in more than one port: the corpus pins the type
/// because two ports disagreeing about whether "1" is a band is exactly
/// the divergence a shared corpus exists to remove.
fn bandof(b: ?*v.Value) f64 {
    const band = v.get(v.get(b, "order"), "band");
    return if (v.isNum(band)) v.asNum(band) else 0;
}

fn posof(b: ?*v.Value) f64 {
    const p = v.get(b, "pos");
    return if (v.isNum(p)) v.asNum(p) else 0;
}

/// Band first (lower runs first), then `pos` — the position the DOCUMENT
/// visibly states, not the order instances happened to load and not the
/// incarnation `seq`.
fn lessRank(_: void, a: *v.Value, b: *v.Value) bool {
    const ab = bandof(a);
    const bb = bandof(b);
    if (ab != bb) return ab < bb;
    return posof(a) < posof(b);
}

/// Was a constraint actually declared? An ABSENT one and an EMPTY LIST
/// are both "no constraint"; only a non-empty spelling is an edge.
fn declared(spec: ?*v.Value) bool {
    if (v.isList(spec)) return v.len(spec) > 0;
    if (v.isStr(spec)) return v.asStr(spec).len > 0;
    return false;
}

/// Matching is by REF, or by NAME across all of that definition's
/// instances (§7) — which is the whole reason the two spellings exist.
fn targets(spec: ?*v.Value, nodes: ?*v.Value) [][]const u8 {
    var hit = v.List([]const u8).init(v.arena());
    const specs: []*v.Value = if (v.isList(spec)) v.items(spec) else blk: {
        const one = v.arena().alloc(*v.Value, 1) catch @panic("oom");
        one[0] = spec orelse v.vnull();
        break :blk one;
    };
    for (specs) |oneval| {
        if (!v.isStr(oneval)) continue;
        const one = v.asStr(oneval);
        for (v.items(nodes)) |node| {
            const r = v.asStr(v.get(node, "ref"));
            var already = false;
            for (hit.items) |x| {
                if (std.mem.eql(u8, x, r)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            if (std.mem.eql(u8, r, one) or std.mem.eql(u8, ref.refname(r), one)) {
                hit.append(r) catch @panic("oom");
            }
        }
    }
    return hit.items;
}

/// A PIN IS NOT A CONSTRAINT (§7).
///
/// Constraints and bands are negotiable by definition — they are what
/// plugins and documents say they want, and the sort's job is to satisfy
/// them all. A pin is the host stating a structural invariant of its own
/// architecture, which is a different kind of claim and must not lose a
/// tie to a document.
///
/// So a pin PLACES the binding at the named end, and an ordering that
/// would move it away is `plugin_order_pinned` — rejected, not honoured
/// into a broken wrap.
fn applypin(order: *v.Value, edges: *v.Value, pin: ?*v.Value) t.Err!*v.Value {
    if (!v.isMap(pin)) return order;

    var out = v.List([]const u8).init(v.arena());
    for (v.items(order)) |x| out.append(v.asStr(x)) catch @panic("oom");

    // SORTED, not insertion order. A pin map is data — it can arrive
    // from a host's own construction options in any order, and two names
    // pinned to the same end are order-sensitive. Sorted is the one
    // order every language agrees on, and `order/pin#two-names` pins it.
    for (v.sortedKeys(pin)) |name| {
        const want = v.asStr(v.get(pin, name));
        var idx: ?usize = null;
        for (out.items, 0..) |r, j| {
            if (std.mem.eql(u8, ref.refname(r), name)) {
                idx = j;
                break;
            }
        }
        const i = idx orelse continue;

        // `first`/`outermost` is index 0; `last`/`innermost` is the end.
        // §6.2 makes the first chain binding outermost, which is why the
        // vocabulary is positional and why the two spellings pair this
        // way.
        const wantfirst = std.mem.eql(u8, want, "first") or std.mem.eql(u8, want, "outermost");
        const r = out.orderedRemove(i);
        if (wantfirst) out.insert(0, r) catch @panic("oom") else out.append(r) catch @panic("oom");
    }

    // Now check that the placement did not break a constraint. This is
    // the half that makes a pin a rejection rather than an override: the
    // host wins on position, but it does not get to silently discard a
    // relationship a plugin declared.
    const index = v.vmap();
    for (out.items, 0..) |r, i| v.set(index, r, v.vnum(@floatFromInt(i)));
    for (v.sortedKeys(edges)) |from| {
        for (v.items(v.get(edges, from))) |tov| {
            const to = v.asStr(tov);
            if (v.asNum(v.get(index, from)) > v.asNum(v.get(index, to))) {
                const d = v.vmap();
                v.set(d, "before", v.vstr(from));
                v.set(d, "after", v.vstr(to));
                return t.fail("plugin_order_pinned", v.print("a pin would move a binding an ordering constrains: {s} must precede {s}", .{ from, to }), d);
            }
        }
    }

    const result = v.vlist();
    for (out.items) |r| v.push(result, v.vstr(r));
    return result;
}

pub fn resolveorder(bindings: ?*v.Value, pin: ?*v.Value) t.Err!*v.Value {
    const n = v.len(bindings);

    const byref = v.vmap();
    for (v.items(bindings)) |b| v.set(byref, v.asStr(v.get(b, "ref")), b);

    // Constraints are edges. A constraint naming an ABSENT binding is
    // satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
    // load in a host with no test plugin. That is sdkgen's __after__
    // behaviour, kept.
    const edges = v.vmap();
    for (v.items(bindings)) |b| v.set(edges, v.asStr(v.get(b, "ref")), v.vlist());

    for (v.items(bindings)) |b| {
        const bref = v.asStr(v.get(b, "ref"));
        const o = v.get(b, "order");
        if (declared(v.get(o, "after"))) {
            for (targets(v.get(o, "after"), bindings)) |x| v.push(v.get(edges, x), v.vstr(bref));
        }
        if (declared(v.get(o, "before"))) {
            for (targets(v.get(o, "before"), bindings)) |x| v.push(v.get(edges, bref), v.vstr(x));
        }
    }

    // Stable topological sort.
    const indeg = v.vmap();
    for (v.items(bindings)) |b| v.set(indeg, v.asStr(v.get(b, "ref")), v.vnum(0));
    for (v.keys(edges)) |from| {
        for (v.items(v.get(edges, from))) |tov| {
            const to = v.asStr(tov);
            v.set(indeg, to, v.vnum(v.asNum(v.get(indeg, to)) + 1));
        }
    }

    var ready = v.List(*v.Value).init(v.arena());
    for (v.items(bindings)) |b| {
        if (v.asNum(v.get(indeg, v.asStr(v.get(b, "ref")))) == 0) ready.append(b) catch @panic("oom");
    }

    var out = v.List([]const u8).init(v.arena());
    while (ready.items.len > 0) {
        std.mem.sort(*v.Value, ready.items, {}, lessRank);
        const next = ready.orderedRemove(0);
        const nref = v.asStr(v.get(next, "ref"));
        out.append(nref) catch @panic("oom");
        for (v.items(v.get(edges, nref))) |tov| {
            const to = v.asStr(tov);
            const d = v.asNum(v.get(indeg, to)) - 1;
            v.set(indeg, to, v.vnum(d));
            if (d == 0) ready.append(v.get(byref, to)) catch @panic("oom");
        }
    }

    if (out.items.len != n) {
        const stuck = v.vlist();
        var text = v.List(u8).init(v.arena());
        text.appendSlice("before/after constraints cycle: ") catch @panic("oom");
        for (v.items(bindings)) |b| {
            const r = v.asStr(v.get(b, "ref"));
            var placed = false;
            for (out.items) |x| {
                if (std.mem.eql(u8, x, r)) {
                    placed = true;
                    break;
                }
            }
            if (placed) continue;
            if (v.len(stuck) > 0) text.appendSlice(" -> ") catch @panic("oom");
            text.appendSlice(r) catch @panic("oom");
            v.push(stuck, v.vstr(r));
        }
        return t.fail("plugin_order_cycle", text.items, t.details1("cycle", stuck));
    }

    const ordered = v.vlist();
    for (out.items) |r| v.push(ordered, v.vstr(r));
    return applypin(ordered, edges, pin);
}
