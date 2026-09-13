// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/depend.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Dependency cardinality, policy, and the restart graph (§11.3).
//!
//! TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
//! because only it knows what it can cope with:
//!
//!                | static (default)          | dynamic
//!   -------------|---------------------------|--------------------------
//!   mandatory    | unmet -> pending;         | unmet -> pending;
//!   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
//!                |          recursively      |          notified
//!   -------------|---------------------------|--------------------------
//!   optional:true| never gates activation;   | never gates activation;
//!                | a change deactivates and  | a change is a
//!                | reactivates               | notification, nothing else
//!
//! `dynamic` means the plugin has said, IN WRITING, that it can survive
//! its provider being swapped underneath it. It is not the default
//! because most plugins cannot, and the cost of wrongly assuming they
//! can is a live instance holding a dead reference.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const ref = @import("ref.zig");

/// A bare string is shorthand for `{name}`.
pub fn normrequire(r: ?*v.Value) *v.Value {
    if (v.isStr(r)) {
        const out = v.vmap();
        v.set(out, "name", r);
        return out;
    }
    return if (v.isMap(r)) r.? else v.vmap();
}

/// BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
///
/// The instance-level `policy` and `optional` list are how a DOCUMENT
/// states the axis without editing the definition, and they apply to
/// every requirement. The per-requirement form is strictly more
/// expressive: an instance that is `static` on its store and `dynamic`
/// on its metrics cannot be written at all at the instance level, and
/// that is the ordinary case rather than an exotic one.
///
/// `optional` UNIONS rather than overriding — both spellings say this
/// requirement need not gate activation, and there is no reading under
/// which one of them means "actually, mandatory".
pub fn requirements(options: ?*v.Value) *v.Value {
    const raw = v.get(options, "requires");
    const marked = v.get(options, "optional");
    const fallback = v.get(options, "policy");

    const out = v.vlist();
    for (v.items(raw)) |item| {
        const r = normrequire(item);
        const o = v.vmap();
        for (v.keys(r)) |k| v.set(o, k, v.get(r, k));

        var opt = v.truthy(v.get(r, "optional"));
        if (!opt and v.isList(marked)) {
            for (v.items(marked)) |m| {
                if (v.same(m, v.get(r, "name"))) {
                    opt = true;
                    break;
                }
            }
        }
        if (opt) v.set(o, "optional", v.vbool(true));

        if (v.isNull(v.get(o, "policy")) and !v.isNull(fallback)) v.set(o, "policy", fallback);
        v.push(out, o);
    }
    return out;
}

/// Does losing this requirement's SELECTED provider restart the
/// consumer? The mandatory ones under `static`, and the `static`
/// optional ones — both make a capability change deactivate and
/// reactivate. `dynamic` never restarts.
pub fn restartsonloss(r: ?*v.Value) bool {
    const p = v.get(r, "policy");
    const policy = if (v.isStr(p)) v.asStr(p) else "static";
    return !std.mem.eql(u8, policy, "dynamic");
}

/// Does an unmet requirement keep the consumer out of `live`?
///
/// CARDINALITY ALONE DECIDES THIS, NOT POLICY. `dynamic` is a statement
/// about surviving a SWAP, not about starting without the thing at all —
/// a mandatory-dynamic consumer still waits in `pending` for its first
/// provider. Conflating the two would let a plugin that declared it can
/// cope with replacement activate with nothing to call.
pub fn gatesactivation(r: ?*v.Value) bool {
    return v.asBool(v.get(r, "optional")) != true;
}

/// Edges that can cause a restart, which is exactly the set a cycle must
/// be detected over (§11.3): the mandatory requirements AND THE `static`
/// OPTIONAL ONES, because both make a capability change deactivate and
/// reactivate the consumer — and a cycle of restarts does not settle.
///
/// ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
/// exclusion was for. An earlier draft of §11.3 excluded EVERY optional
/// edge and thereby admitted the non-terminating case it was trying to
/// permit.
pub fn restartcausing(r: ?*v.Value) bool {
    return gatesactivation(r) or restartsonloss(r);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn listhas(l: []const []const u8, s: []const u8) bool {
    for (l) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

pub fn dependencycycle(nodes: ?*v.Value) ?*v.Value {
    // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    // matched differently — a capability by its exact name, a ref
    // through the canonical spelling (§4 rule 5) — and one map keyed by
    // both can only do one of them. Keyed by both and looked up raw, a
    // cycle spelled `a$`/`b$` finds no providers and EVADES the
    // load-time check that exists to catch a non-terminating reconcile.
    const bycap = v.vmap();
    const isref = v.vmap();
    for (v.items(nodes)) |n| {
        const nref = v.asStr(v.get(n, "ref"));
        v.set(isref, nref, v.vbool(true));
        for (v.items(v.get(n, "provides"))) |capv| {
            const c = v.asStr(capv);
            var l = v.get(bycap, c);
            if (v.isNull(l)) {
                l = v.vlist();
                v.set(bycap, c, l);
            }
            v.push(l, v.vstr(nref));
        }
    }

    const edges = v.vmap();
    for (v.items(nodes)) |n| {
        const nref = v.asStr(v.get(n, "ref"));
        var out = v.List([]const u8).init(v.arena());
        for (v.items(v.get(n, "requires"))) |r| {
            if (!restartcausing(r)) continue;
            const rname = if (v.isStr(v.get(r, "name"))) v.asStr(v.get(r, "name")) else "";
            var from = v.List([]const u8).init(v.arena());
            for (v.items(v.get(bycap, rname))) |x| from.append(v.asStr(x)) catch @panic("oom");
            // A node satisfies its own name AS A REF (§11.1),
            // canonically — exactly what `providersof` does at runtime,
            // so the load-time graph and the running one agree about
            // what an edge is.
            if (ref.tryref(rname)) |asref| {
                if (v.has(isref, asref) and !listhas(from.items, asref)) {
                    from.append(asref) catch @panic("oom");
                }
            }
            for (from.items) |p| {
                if (!std.mem.eql(u8, p, nref) and !listhas(out.items, p)) {
                    out.append(p) catch @panic("oom");
                }
            }
        }
        std.mem.sort([]const u8, out.items, {}, lessStr);
        const sorted = v.vlist();
        for (out.items) |p| v.push(sorted, v.vstr(p));
        v.set(edges, nref, sorted);
    }

    // Iterative DFS with an explicit stack: twenty ports, and several of
    // them have no recursion budget worth relying on.
    const WHITE: f64 = 0;
    const GREY: f64 = 1;
    const BLACK: f64 = 2;
    const colour = v.vmap();
    for (v.items(nodes)) |n| v.set(colour, v.asStr(v.get(n, "ref")), v.vnum(WHITE));

    const Frame = struct { ref: []const u8, i: usize };

    for (v.sortedKeys(edges)) |start| {
        if (v.asNum(v.get(colour, start)) != WHITE) continue;

        var path = v.List([]const u8).init(v.arena());
        var stack = v.List(Frame).init(v.arena());
        stack.append(.{ .ref = start, .i = 0 }) catch @panic("oom");
        v.set(colour, start, v.vnum(GREY));
        path.append(start) catch @panic("oom");

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const tos = v.get(edges, top.ref);

            if (top.i >= v.len(tos)) {
                v.set(colour, top.ref, v.vnum(BLACK));
                _ = stack.pop();
                _ = path.pop();
                continue;
            }

            const next = v.asStr(v.at(tos, top.i));
            top.i += 1;
            const c = v.asNum(v.get(colour, next));

            if (c == GREY) {
                // Report the cycle itself, not the walk that found it.
                const cycle = v.vlist();
                var started = false;
                for (path.items) |p| {
                    if (!started and std.mem.eql(u8, p, next)) started = true;
                    if (started) v.push(cycle, v.vstr(p));
                }
                v.push(cycle, v.vstr(next));
                return cycle;
            }
            if (c == BLACK) continue;

            v.set(colour, next, v.vnum(GREY));
            path.append(next) catch @panic("oom");
            stack.append(.{ .ref = next, .i = 0 }) catch @panic("oom");
        }
    }

    return null;
}

/// Raise on a cycle, naming it. Separate from the detector so the
/// detector stays pure and corpus-testable.
pub fn checkcycle(nodes: ?*v.Value) t.Err!void {
    const cycle = dependencycycle(nodes) orelse return;
    var text = v.List(u8).init(v.arena());
    text.appendSlice("requirements cycle: ") catch @panic("oom");
    for (v.items(cycle), 0..) |x, i| {
        if (i > 0) text.appendSlice(" -> ") catch @panic("oom");
        text.appendSlice(v.asStr(x)) catch @panic("oom");
    }
    return t.fail("plugin_dependency_cycle", text.items, t.details1("cycle", cycle));
}
